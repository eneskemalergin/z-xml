//! Compile-time reader shape and lifecycle contract.

const std = @import("std");

/// XML capability profile selected at compile time.
pub const Profile = enum {
    xml10_utf8_no_dtd,
    xml10_utf8_ns_no_dtd,
    xml10_nonvalidating,
    xml10_ns_nonvalidating,
    xml10_dtd_validating,
    xml10_ns_dtd_validating,
    xml11_nonvalidating,
    xml11_ns_nonvalidating,
    xml11_dtd_validating,
    xml11_ns_dtd_validating,

    /// Returns whether namespace processing is required by this profile.
    pub fn hasNamespaces(comptime self: Profile) bool {
        return switch (self) {
            .xml10_utf8_ns_no_dtd,
            .xml10_ns_nonvalidating,
            .xml10_ns_dtd_validating,
            .xml11_ns_nonvalidating,
            .xml11_ns_dtd_validating,
            => true,
            else => false,
        };
    }

    /// Returns the DTD processing mode required by this profile.
    pub fn dtdMode(comptime self: Profile) DtdMode {
        return switch (self) {
            .xml10_utf8_no_dtd, .xml10_utf8_ns_no_dtd => .rejected,
            .xml10_nonvalidating,
            .xml10_ns_nonvalidating,
            .xml11_nonvalidating,
            .xml11_ns_nonvalidating,
            => .nonvalidating,
            .xml10_dtd_validating,
            .xml10_ns_dtd_validating,
            .xml11_dtd_validating,
            .xml11_ns_dtd_validating,
            => .validating,
        };
    }

    /// Returns whether the profile includes XML 1.1 behavior.
    pub fn isXml11(comptime self: Profile) bool {
        return switch (self) {
            .xml11_nonvalidating,
            .xml11_ns_nonvalidating,
            .xml11_dtd_validating,
            .xml11_ns_dtd_validating,
            => true,
            else => false,
        };
    }

    /// Returns whether the profile is the UTF-8-only core subset.
    pub fn isUtf8Only(comptime self: Profile) bool {
        return switch (self) {
            .xml10_utf8_no_dtd, .xml10_utf8_ns_no_dtd => true,
            else => false,
        };
    }
};

/// DTD capability implied by a profile.
pub const DtdMode = enum {
    rejected,
    nonvalidating,
    validating,
};

/// Optional event detail selected at compile time.
pub const Report = enum {
    semantic,
    detailed,
};

/// Diagnostic location detail selected at compile time.
pub const DiagnosticLocation = enum {
    byte_offset,
    line_column,
};

/// Compile-time reader configuration.
pub const Config = struct {
    profile: Profile,
    report: Report = .semantic,
    diagnostic_location: DiagnosticLocation = .line_column,
    event_locations: bool = false,

    /// Rejects combinations whose promised events cannot exist in a profile.
    pub fn validate(comptime self: Config) void {
        if (self.report == .detailed and self.profile.dtdMode() == .rejected) {
            @compileError("detailed reporting requires a DTD-capable profile");
        }
    }
};

/// Reviewed configurations for normal callers and benchmark lanes.
pub const Configs = struct {
    /// Line-aware XML 1.0 UTF-8 core profile.
    pub const XML10_UTF8_NO_DTD: Config = .{
        .profile = .xml10_utf8_no_dtd,
    };
    /// Byte-offset-only XML 1.0 UTF-8 performance profile.
    pub const XML10_UTF8_NO_DTD_FAST: Config = .{
        .profile = .xml10_utf8_no_dtd,
        .diagnostic_location = .byte_offset,
    };
    /// XML 1.0 UTF-8 core profile with line-aware event spans.
    pub const XML10_UTF8_NO_DTD_LOCATED: Config = .{
        .profile = .xml10_utf8_no_dtd,
        .event_locations = true,
    };
    /// Namespace-aware XML 1.0 UTF-8 core profile.
    pub const XML10_UTF8_NAMESPACES_NO_DTD: Config = .{
        .profile = .xml10_utf8_ns_no_dtd,
    };
    /// Full non-validating XML 1.0 profile without namespaces.
    pub const XML10_NONVALIDATING: Config = .{
        .profile = .xml10_nonvalidating,
    };
    /// Full namespace-aware non-validating XML 1.0 profile.
    pub const XML10_NAMESPACES_NONVALIDATING: Config = .{
        .profile = .xml10_ns_nonvalidating,
    };
    /// DTD-validating XML 1.0 profile without namespaces.
    pub const XML10_VALIDATING: Config = .{
        .profile = .xml10_dtd_validating,
    };
    /// Detailed namespace-aware DTD-validating XML 1.0 profile.
    pub const XML10_NAMESPACES_VALIDATING_DETAILED: Config = .{
        .profile = .xml10_ns_dtd_validating,
        .report = .detailed,
        .event_locations = true,
    };
    /// Namespace-aware DTD-validating XML 1.1 profile.
    pub const XML11_NAMESPACES_VALIDATING: Config = .{
        .profile = .xml11_ns_dtd_validating,
    };
};

/// Reader reset policy.
pub const ResetMode = enum {
    retain_capacity,
    release_memory,
};

/// Observable reader lifecycle.
pub const Lifecycle = enum {
    ready,
    producing,
    needs_input,
    failed,
    done,
    deinitialized,
};

/// Initial limits represented in the lifecycle spike.
pub const Limits = struct {
    /// Maximum simultaneously open element count.
    max_depth: usize = 256,
    /// Maximum cumulative raw-name bytes for open elements.
    max_open_name_bytes: usize = 1024 * 1024,
    /// Maximum bytes accepted in one unfinished token.
    max_partial_token_bytes: usize = 64 * 1024,
    /// Maximum bytes exposed by one future fragmented event.
    max_fragment_bytes: usize = 64 * 1024,
    /// Maximum owned capacity retained across a retain reset.
    max_retained_bytes: usize = 1024 * 1024,

    fn validate(self: Limits) bool {
        return self.max_depth > 0 and
            self.max_open_name_bytes > 0 and
            self.max_partial_token_bytes > 0 and
            self.max_fragment_bytes > 0;
    }
};

/// Categories of memory owned by a reader.
pub const MemoryUsage = struct {
    /// Number of active open-element frames.
    parser_stack_len: usize = 0,
    /// Open-element frame capacity measured in frame slots.
    parser_stack_capacity: usize = 0,
    /// Active raw-name bytes owned by open frames and an unfinished start tag.
    open_name_bytes: usize = 0,
    /// Raw-name arena capacity measured in bytes.
    open_name_capacity: usize = 0,
    /// General scratch capacity measured in bytes.
    scratch_capacity: usize = 0,
    /// Namespace storage capacity measured in bytes.
    namespace_capacity: usize = 0,
    /// DTD storage capacity measured in bytes.
    dtd_capacity: usize = 0,
    /// Validation storage capacity measured in bytes.
    validation_capacity: usize = 0,
    /// Total reader-owned reusable capacity measured in bytes.
    retained_capacity: usize = 0,
};

/// Stable diagnostic category for the compiled lifecycle API.
pub const DiagnosticCode = enum {
    invalid_state,
    unsupported_stage,
    empty_document,
    unexpected_document_text,
    malformed_start_tag,
    malformed_end_tag,
    unexpected_end_tag,
    mismatched_end_tag,
    unclosed_element,
    incomplete_input,
    multiple_document_elements,
    trailing_content,
    depth_limit,
    open_name_limit,
    partial_token_limit,
    read_failed,
};

/// Location containing the precision selected by `config`.
pub fn Location(comptime config: Config) type {
    config.validate();
    return if (config.diagnostic_location == .line_column)
        struct {
            source_id: u32 = 0,
            byte_offset: u64 = 0,
            line: u64 = 1,
            byte_column: u64 = 1,
        }
    else
        struct {
            source_id: u32 = 0,
            byte_offset: u64 = 0,
        };
}

/// Diagnostic type specialized to the selected location precision.
pub fn Diagnostic(comptime config: Config) type {
    return struct {
        code: DiagnosticCode,
        primary: Location(config),
        related: ?Location(config) = null,
    };
}

fn ResolverOptions(comptime config: Config) type {
    return if (config.profile.dtdMode() == .rejected)
        struct {}
    else
        struct {
            context: ?*anyopaque = null,
        };
}

fn ValidationOptions(comptime config: Config) type {
    return if (config.profile.dtdMode() == .validating)
        struct {
            collect_validity_errors: bool = false,
        }
    else
        struct {};
}

/// Runtime options containing only state permitted by `config`.
pub fn Options(comptime config: Config) type {
    config.validate();
    return struct {
        limits: Limits = .{},
        resolver: ResolverOptions(config) = .{},
        validation: ValidationOptions(config) = .{},
    };
}

const RawName = struct {
    raw: []const u8,
};

const ExpandedName = struct {
    raw: []const u8,
    prefix: ?[]const u8,
    local: []const u8,
    namespace_uri: ?[]const u8,
};

fn Name(comptime config: Config) type {
    return if (config.profile.hasNamespaces()) ExpandedName else RawName;
}

fn StartElement(comptime config: Config) type {
    return struct {
        name: Name(config),
        empty_element_syntax: bool,
    };
}

fn EndElement(comptime config: Config) type {
    return struct {
        name: Name(config),
    };
}

const DocumentStart = struct {};
const DocumentEnd = struct {};
const DocumentType = struct {
    root_name: []const u8,
};
const Text = struct {
    bytes: []const u8,
};
const Comment = struct {
    bytes: []const u8,
    complete: bool,
};
const ProcessingInstruction = struct {
    target: []const u8,
    data: []const u8,
    complete: bool,
};
const Declaration = struct {
    name: []const u8,
};
const EntityBoundary = struct {
    name: []const u8,
};

fn NoDtdEventPayload(comptime config: Config) type {
    return union(enum) {
        document_start: DocumentStart,
        start_element: StartElement(config),
        end_element: EndElement(config),
        text: Text,
        comment: Comment,
        processing_instruction: ProcessingInstruction,
        document_end: DocumentEnd,
    };
}

fn DtdEventPayload(comptime config: Config) type {
    return union(enum) {
        document_start: DocumentStart,
        document_type: DocumentType,
        notation_declaration: Declaration,
        unparsed_entity_declaration: Declaration,
        start_element: StartElement(config),
        end_element: EndElement(config),
        text: Text,
        comment: Comment,
        processing_instruction: ProcessingInstruction,
        skipped_entity: Declaration,
        document_end: DocumentEnd,
    };
}

fn DetailedDtdEventPayload(comptime config: Config) type {
    return union(enum) {
        document_start: DocumentStart,
        document_type: DocumentType,
        notation_declaration: Declaration,
        unparsed_entity_declaration: Declaration,
        element_declaration: Declaration,
        attribute_list_declaration: Declaration,
        parsed_entity_declaration: Declaration,
        entity_start: EntityBoundary,
        entity_end: EntityBoundary,
        start_element: StartElement(config),
        end_element: EndElement(config),
        text: Text,
        comment: Comment,
        processing_instruction: ProcessingInstruction,
        skipped_entity: Declaration,
        document_end: DocumentEnd,
    };
}

fn EventPayload(comptime config: Config) type {
    config.validate();
    if (config.profile.dtdMode() == .rejected) return NoDtdEventPayload(config);
    if (config.report == .detailed) return DetailedDtdEventPayload(config);
    return DtdEventPayload(config);
}

fn Span(comptime config: Config) type {
    return struct {
        start: Location(config),
        end: Location(config),
    };
}

/// Semantic event type with impossible tags removed at compile time.
pub fn Event(comptime config: Config) type {
    config.validate();
    return if (config.event_locations)
        struct {
            payload: EventPayload(config),
            span: Span(config),
        }
    else
        EventPayload(config);
}

/// Pull-reader result.
pub fn Step(comptime config: Config) type {
    return union(enum) {
        event: Event(config),
        need_input,
        done,
    };
}

/// Errors reported while constructing a reader.
pub const InitError = error{
    InvalidOptions,
};

/// Errors reported while installing an input chunk.
pub const FeedError = error{
    InvalidState,
};

/// Errors reported while producing an event.
pub const ReadError = error{
    InvalidXml,
    InvalidDtd,
    NotValid,
    UnsupportedFeature,
    LimitExceeded,
    ResolverFailed,
    ReadFailed,
    Cancelled,
    OutOfMemory,
    InvalidState,
};

/// Errors reported while resetting a reader.
pub const ResetError = error{
    InvalidState,
};

fn PositionState(comptime config: Config) type {
    return if (config.diagnostic_location == .line_column)
        struct {
            line: u64 = 1,
            line_start_offset: u64 = 0,
            pending_carriage_return: bool = false,
        }
    else
        struct {};
}

const VerticalState = enum {
    emit_document_start,
    before_root,
    before_root_markup,
    content,
    content_markup,
    after_root,
    after_root_markup,
    start_name,
    start_after_space,
    empty_slash,
    emit_start_element,
    emit_empty_start_element,
    emit_end_element,
    end_expect_name,
    end_name,
    end_after_space,
    release_closed_element,
    emit_document_end,
    complete,
};

fn OpenElementFrame(comptime config: Config) type {
    return struct {
        name_offset: usize,
        name_len: usize,
        start: Location(config),
    };
}

const Failure = enum {
    invalid_xml,
    unsupported_feature,
    limit_exceeded,
    out_of_memory,
    read_failed,
};

/// Incremental reader specialized to `config`.
pub fn Reader(comptime config: Config) type {
    config.validate();

    return struct {
        const Self = @This();
        const no_end_mismatch = std.math.maxInt(usize);

        allocator: std.mem.Allocator,
        options: Options(config),
        lifecycle: Lifecycle = .ready,
        input: []const u8 = &.{},
        cursor: usize = 0,
        final_input: bool = false,
        final_was_seen: bool = false,
        source_byte_offset: u64 = 0,
        position: PositionState(config) = .{},
        first_diagnostic: ?Diagnostic(config) = null,
        vertical_state: VerticalState = .emit_document_start,
        failure: ?Failure = null,
        open_elements: std.ArrayList(OpenElementFrame(config)) = .empty,
        open_names: std.ArrayList(u8) = .empty,
        token_start: Location(config) = .{},
        token_name_len: usize = 0,
        end_mismatch_index: usize = no_end_mismatch,

        /// Initializes a reader without allocating.
        pub fn init(allocator: std.mem.Allocator, options: Options(config)) InitError!Self {
            if (!options.limits.validate()) return error.InvalidOptions;
            return .{
                .allocator = allocator,
                .options = options,
            };
        }

        /// Releases all reader-owned memory and invalidates the reader.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.lifecycle != .deinitialized);
            self.releaseStorage();
            self.input = &.{};
            self.cursor = 0;
            self.first_diagnostic = null;
            self.lifecycle = .deinitialized;
        }

        /// Clears document state using the selected capacity policy.
        pub fn reset(self: *Self, mode: ResetMode) ResetError!void {
            if (self.lifecycle == .deinitialized) return error.InvalidState;
            switch (mode) {
                .retain_capacity => {
                    if (self.retainedCapacity() > self.options.limits.max_retained_bytes) {
                        self.releaseStorage();
                    } else {
                        self.open_elements.clearRetainingCapacity();
                        self.open_names.clearRetainingCapacity();
                    }
                },
                .release_memory => self.releaseStorage(),
            }
            self.lifecycle = .ready;
            self.input = &.{};
            self.cursor = 0;
            self.final_input = false;
            self.final_was_seen = false;
            self.source_byte_offset = 0;
            self.position = .{};
            self.first_diagnostic = null;
            self.vertical_state = .emit_document_start;
            self.failure = null;
            self.token_start = .{};
            self.token_name_len = 0;
            self.end_mismatch_index = no_end_mismatch;
        }

        /// Installs one caller-owned input chunk.
        pub fn feed(self: *Self, input: []const u8, final: bool) FeedError!void {
            if (self.lifecycle != .ready and self.lifecycle != .needs_input) {
                return error.InvalidState;
            }
            if (self.final_was_seen or (input.len == 0 and !final)) {
                return error.InvalidState;
            }

            self.input = input;
            self.cursor = 0;
            self.final_input = final;
            self.final_was_seen = final;
            self.lifecycle = .producing;
        }

        /// Produces the next event from the current implementation stage.
        pub fn next(self: *Self) ReadError!Step(config) {
            switch (self.lifecycle) {
                .ready, .needs_input, .deinitialized => return error.InvalidState,
                .failed => return self.failureError(),
                .done => return .done,
                .producing => {},
            }

            while (true) {
                switch (self.vertical_state) {
                    .emit_document_start => {
                        self.vertical_state = .before_root;
                        const location = self.currentLocation();
                        return self.eventStep(
                            .{ .document_start = .{} },
                            location,
                            location,
                        );
                    },
                    .before_root => {
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.empty_document, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '<') {
                            return self.fail(.unexpected_document_text, .invalid_xml);
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .before_root_markup;
                    },
                    .before_root_markup => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '!' or byte == '?') {
                            return self.fail(.unsupported_stage, .unsupported_feature);
                        }
                        if (byte == '/') {
                            return self.fail(.unexpected_end_tag, .invalid_xml);
                        }
                        if (!isAsciiNameStart(byte)) {
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        try self.beginStartElement();
                    },
                    .content => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                const frame = self.topFrame();
                                return self.failRelated(
                                    .unclosed_element,
                                    .invalid_xml,
                                    self.currentLocation(),
                                    frame.start,
                                );
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '<') {
                            return self.fail(.unsupported_stage, .unsupported_feature);
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .content_markup;
                    },
                    .content_markup => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '/') {
                            self.consumeByte('/');
                            self.vertical_state = .end_expect_name;
                            continue;
                        }
                        if (byte == '!' or byte == '?') {
                            return self.fail(.unsupported_stage, .unsupported_feature);
                        }
                        if (!isAsciiNameStart(byte)) {
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        try self.beginStartElement();
                    },
                    .after_root => {
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                self.vertical_state = .emit_document_end;
                                continue;
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '<') {
                            return self.fail(.trailing_content, .invalid_xml);
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .after_root_markup;
                    },
                    .after_root_markup => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '/') {
                            return self.fail(.unexpected_end_tag, .invalid_xml);
                        }
                        if (byte == '!' or byte == '?') {
                            return self.fail(.unsupported_stage, .unsupported_feature);
                        }
                        if (isAsciiNameStart(byte)) {
                            return self.failAt(
                                .multiple_document_elements,
                                .invalid_xml,
                                self.token_start,
                            );
                        }
                        return self.fail(.trailing_content, .invalid_xml);
                    },
                    .start_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (run_end < self.input.len and isAsciiNameChar(self.input[run_end])) {
                            run_end += 1;
                        }
                        try self.appendStartNameRun(self.input[run_start..run_end]);

                        if (self.cursor < self.input.len) {
                            const byte = self.input[self.cursor];
                            if (byte == '/') {
                                self.consumeByte(byte);
                                self.vertical_state = .empty_slash;
                                continue;
                            }
                            if (byte == '>') {
                                self.consumeByte(byte);
                                try self.finishStartElement(false);
                                continue;
                            }
                            if (isXmlWhitespace(byte)) {
                                self.vertical_state = .start_after_space;
                                continue;
                            }
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .start_after_space => {
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '>') {
                            self.consumeByte(byte);
                            try self.finishStartElement(false);
                            continue;
                        }
                        if (byte == '/') {
                            self.consumeByte(byte);
                            self.vertical_state = .empty_slash;
                            continue;
                        }
                        if (isAsciiNameStart(byte)) {
                            return self.fail(.unsupported_stage, .unsupported_feature);
                        }
                        return self.fail(.malformed_start_tag, .invalid_xml);
                    },
                    .empty_slash => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '>') {
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        self.consumeByte('>');
                        try self.finishStartElement(true);
                    },
                    .emit_start_element => {
                        self.vertical_state = .content;
                        return self.eventStep(
                            .{ .start_element = .{
                                .name = self.topName(),
                                .empty_element_syntax = false,
                            } },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .emit_empty_start_element => {
                        self.vertical_state = .emit_end_element;
                        return self.eventStep(
                            .{ .start_element = .{
                                .name = self.topName(),
                                .empty_element_syntax = true,
                            } },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .emit_end_element => {
                        self.vertical_state = .release_closed_element;
                        return self.eventStep(
                            .{ .end_element = .{ .name = self.topName() } },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .end_expect_name => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (!isAsciiNameStart(self.input[self.cursor])) {
                            return self.fail(.malformed_end_tag, .invalid_xml);
                        }
                        self.token_name_len = 0;
                        self.end_mismatch_index = no_end_mismatch;
                        self.vertical_state = .end_name;
                    },
                    .end_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (run_end < self.input.len and isAsciiNameChar(self.input[run_end])) {
                            run_end += 1;
                        }
                        try self.compareAndConsumeEndName(self.input[run_start..run_end]);

                        if (self.cursor < self.input.len) {
                            const byte = self.input[self.cursor];
                            if (byte == '>') {
                                self.recordShortEndMismatch();
                                self.consumeByte(byte);
                                try self.finishEndElement();
                                continue;
                            }
                            if (isXmlWhitespace(byte)) {
                                self.recordShortEndMismatch();
                                self.vertical_state = .end_after_space;
                                continue;
                            }
                            return self.fail(.malformed_end_tag, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .end_after_space => {
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '>') {
                            return self.fail(.malformed_end_tag, .invalid_xml);
                        }
                        self.consumeByte('>');
                        try self.finishEndElement();
                    },
                    .release_closed_element => {
                        self.releaseTopElement();
                        self.vertical_state = if (self.open_elements.items.len == 0)
                            .after_root
                        else
                            .content;
                    },
                    .emit_document_end => {
                        self.vertical_state = .complete;
                        const location = self.currentLocation();
                        return self.eventStep(
                            .{ .document_end = .{} },
                            location,
                            location,
                        );
                    },
                    .complete => {
                        self.lifecycle = .done;
                        return .done;
                    },
                }
            }
        }

        /// Returns the first sticky diagnostic, if one exists.
        pub fn diagnostic(self: *const Self) ?Diagnostic(config) {
            return self.first_diagnostic;
        }

        /// Reports memory currently owned by the reader.
        pub fn memoryUsage(self: *const Self) MemoryUsage {
            return .{
                .parser_stack_len = self.open_elements.items.len,
                .parser_stack_capacity = self.open_elements.capacity,
                .open_name_bytes = self.open_names.items.len,
                .open_name_capacity = self.open_names.capacity,
                .retained_capacity = self.retainedCapacity(),
            };
        }

        fn retainedCapacity(self: *const Self) usize {
            const stack_bytes = self.open_elements.capacity *| @sizeOf(OpenElementFrame(config));
            return stack_bytes +| self.open_names.capacity;
        }

        fn releaseStorage(self: *Self) void {
            self.open_elements.deinit(self.allocator);
            self.open_names.deinit(self.allocator);
            self.open_elements = .empty;
            self.open_names = .empty;
        }

        fn beginStartElement(self: *Self) ReadError!void {
            if (self.open_elements.items.len == self.options.limits.max_depth) {
                return self.failVoid(.depth_limit, .limit_exceeded);
            }
            self.token_name_len = 0;
            self.vertical_state = .start_name;
        }

        fn appendStartNameRun(self: *Self, run: []const u8) ReadError!void {
            const partial_remaining = std.math.sub(
                usize,
                self.options.limits.max_partial_token_bytes,
                self.token_name_len,
            ) catch unreachable;
            const open_remaining = std.math.sub(
                usize,
                self.options.limits.max_open_name_bytes,
                self.open_names.items.len,
            ) catch unreachable;
            const accepted_len = @min(run.len, @min(partial_remaining, open_remaining));
            if (accepted_len > 0) {
                self.open_names.appendSlice(
                    self.allocator,
                    run[0..accepted_len],
                ) catch return self.failOutOfMemory();
                self.consumeRun(run[0..accepted_len]);
                self.token_name_len += accepted_len;
            }
            if (accepted_len != run.len) {
                if (self.token_name_len == self.options.limits.max_partial_token_bytes) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                return self.failVoid(.open_name_limit, .limit_exceeded);
            }
        }

        fn finishStartElement(self: *Self, empty_element: bool) ReadError!void {
            self.open_elements.append(self.allocator, .{
                .name_offset = self.open_names.items.len - self.token_name_len,
                .name_len = self.token_name_len,
                .start = self.token_start,
            }) catch return self.failOutOfMemory();
            self.vertical_state = if (empty_element)
                .emit_empty_start_element
            else
                .emit_start_element;
        }

        fn compareAndConsumeEndName(self: *Self, run: []const u8) ReadError!void {
            const remaining = std.math.sub(
                usize,
                self.options.limits.max_partial_token_bytes,
                self.token_name_len,
            ) catch unreachable;
            const accepted_len = @min(run.len, remaining);
            const accepted = run[0..accepted_len];
            const raw = self.topRawName();
            if (self.end_mismatch_index == no_end_mismatch) {
                for (accepted, 0..) |byte, index| {
                    const name_index = self.token_name_len + index;
                    if (name_index >= raw.len or raw[name_index] != byte) {
                        self.end_mismatch_index = name_index;
                        break;
                    }
                }
            }
            self.token_name_len += accepted_len;
            self.consumeRun(accepted);
            if (accepted_len != run.len) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
        }

        fn recordShortEndMismatch(self: *Self) void {
            if (self.end_mismatch_index == no_end_mismatch and
                self.token_name_len != self.topFrame().name_len)
            {
                self.end_mismatch_index = self.token_name_len;
            }
        }

        fn finishEndElement(self: *Self) ReadError!void {
            if (self.end_mismatch_index != no_end_mismatch) {
                return self.failRelated(
                    .mismatched_end_tag,
                    .invalid_xml,
                    self.endMismatchLocation(),
                    self.topFrame().start,
                );
            }
            self.vertical_state = .emit_end_element;
        }

        fn releaseTopElement(self: *Self) void {
            const frame = self.topFrame();
            self.open_elements.items.len -= 1;
            self.open_names.items.len = frame.name_offset;
        }

        fn topFrame(self: *const Self) OpenElementFrame(config) {
            std.debug.assert(self.open_elements.items.len > 0);
            return self.open_elements.items[self.open_elements.items.len - 1];
        }

        fn topRawName(self: *const Self) []const u8 {
            const frame = self.topFrame();
            return self.open_names.items[frame.name_offset..][0..frame.name_len];
        }

        fn consumeByte(self: *Self, byte: u8) void {
            std.debug.assert(self.cursor < self.input.len);
            std.debug.assert(self.input[self.cursor] == byte);
            self.consumeRun(self.input[self.cursor .. self.cursor + 1]);
        }

        fn consumeWhitespaceRun(self: *Self) void {
            const start = self.cursor;
            var end = start;
            while (end < self.input.len and isXmlWhitespace(self.input[end])) {
                end += 1;
            }
            self.consumeRun(self.input[start..end]);
        }

        fn consumeRun(self: *Self, run: []const u8) void {
            std.debug.assert(run.len <= self.input.len - self.cursor);
            std.debug.assert(std.mem.eql(u8, run, self.input[self.cursor .. self.cursor + run.len]));

            var source_byte_offset = self.source_byte_offset;

            if (config.diagnostic_location == .line_column) {
                if (run.len > 0 and std.mem.indexOfAny(u8, run, "\r\n") == null) {
                    source_byte_offset += run.len;
                    self.position.pending_carriage_return = false;
                } else {
                    var line = self.position.line;
                    var line_start_offset = self.position.line_start_offset;
                    var pending_carriage_return = self.position.pending_carriage_return;
                    for (run) |byte| {
                        source_byte_offset += 1;
                        if (pending_carriage_return) {
                            pending_carriage_return = false;
                            if (byte == '\n') {
                                line_start_offset = source_byte_offset;
                                continue;
                            }
                        }
                        if (byte == '\r') {
                            line += 1;
                            line_start_offset = source_byte_offset;
                            pending_carriage_return = true;
                        } else if (byte == '\n') {
                            line += 1;
                            line_start_offset = source_byte_offset;
                        }
                    }
                    self.position.line = line;
                    self.position.line_start_offset = line_start_offset;
                    self.position.pending_carriage_return = pending_carriage_return;
                }
            } else {
                source_byte_offset += run.len;
            }

            self.cursor += run.len;
            self.source_byte_offset = source_byte_offset;
        }

        fn topName(self: *const Self) Name(config) {
            const raw = self.topRawName();
            if (comptime config.profile.hasNamespaces()) {
                return .{
                    .raw = raw,
                    .prefix = null,
                    .local = raw,
                    .namespace_uri = null,
                };
            }
            return .{ .raw = raw };
        }

        fn endMismatchLocation(self: *const Self) Location(config) {
            std.debug.assert(self.end_mismatch_index != no_end_mismatch);
            var location = self.token_start;
            const delta: u64 = @intCast(2 + self.end_mismatch_index);
            location.byte_offset += delta;
            if (config.diagnostic_location == .line_column) {
                location.byte_column += delta;
            }
            return location;
        }

        fn eventStep(
            self: *const Self,
            payload: EventPayload(config),
            start: Location(config),
            end: Location(config),
        ) Step(config) {
            _ = self;
            if (config.event_locations) {
                return .{ .event = .{
                    .payload = payload,
                    .span = .{ .start = start, .end = end },
                } };
            }
            return .{ .event = payload };
        }

        fn needInput(self: *Self) Step(config) {
            std.debug.assert(!self.final_input);
            std.debug.assert(self.cursor == self.input.len);
            self.input = &.{};
            self.cursor = 0;
            self.lifecycle = .needs_input;
            return .need_input;
        }

        fn fail(self: *Self, code: DiagnosticCode, failure: Failure) ReadError {
            return self.failAt(code, failure, self.currentLocation());
        }

        fn failAt(
            self: *Self,
            code: DiagnosticCode,
            failure: Failure,
            primary: Location(config),
        ) ReadError {
            self.first_diagnostic = .{ .code = code, .primary = primary };
            self.failure = failure;
            self.lifecycle = .failed;
            return failureToError(failure);
        }

        fn failRelated(
            self: *Self,
            code: DiagnosticCode,
            failure: Failure,
            primary: Location(config),
            related: Location(config),
        ) ReadError {
            self.first_diagnostic = .{
                .code = code,
                .primary = primary,
                .related = related,
            };
            self.failure = failure;
            self.lifecycle = .failed;
            return failureToError(failure);
        }

        fn failVoid(self: *Self, code: DiagnosticCode, failure: Failure) ReadError {
            return self.fail(code, failure);
        }

        fn failOutOfMemory(self: *Self) ReadError {
            self.failure = .out_of_memory;
            self.lifecycle = .failed;
            return error.OutOfMemory;
        }

        fn failureError(self: *const Self) ReadError {
            return failureToError(self.failure orelse unreachable);
        }

        fn currentLocation(self: *const Self) Location(config) {
            if (config.diagnostic_location == .line_column) {
                return .{
                    .byte_offset = self.source_byte_offset,
                    .line = self.position.line,
                    .byte_column = self.source_byte_offset - self.position.line_start_offset + 1,
                };
            }
            return .{
                .byte_offset = self.source_byte_offset,
            };
        }
    };
}

fn failureToError(failure: Failure) ReadError {
    return switch (failure) {
        .invalid_xml => error.InvalidXml,
        .unsupported_feature => error.UnsupportedFeature,
        .limit_exceeded => error.LimitExceeded,
        .out_of_memory => error.OutOfMemory,
        .read_failed => error.ReadFailed,
    };
}

/// Internal bridge used by package adapters without exposing parser state.
pub fn AdapterAccess(comptime config: Config) type {
    return struct {
        pub fn recordReadFailure(reader: *Reader(config)) ReadError {
            return reader.fail(.read_failed, .read_failed);
        }
    };
}

fn isXmlWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isAsciiNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == ':';
}

fn isAsciiNameChar(byte: u8) bool {
    return isAsciiNameStart(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '.';
}
