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
    /// Byte-offset-only namespace-aware XML 1.0 UTF-8 performance profile.
    pub const XML10_UTF8_NAMESPACES_NO_DTD_FAST: Config = .{
        .profile = .xml10_utf8_ns_no_dtd,
        .diagnostic_location = .byte_offset,
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

/// Runtime limits implemented by the current reader stage.
pub const Limits = struct {
    /// Maximum simultaneously open element count.
    max_depth: usize = 256,
    /// Maximum cumulative raw-name bytes for open elements.
    max_open_name_bytes: usize = 1024 * 1024,
    /// Maximum bytes accepted in one unfinished token.
    max_partial_token_bytes: usize = 64 * 1024,
    /// Maximum source attributes accepted on one element.
    max_attributes_per_element: usize = 256,
    /// Maximum raw bytes accepted in one attribute name.
    max_attribute_name_bytes: usize = 64 * 1024,
    /// Maximum semantic bytes accepted in one attribute value.
    max_attribute_value_bytes: usize = 1024 * 1024,
    /// Maximum aggregate name and value bytes accepted on one element.
    max_attribute_bytes_per_element: usize = 1024 * 1024,
    /// Maximum source bytes accepted in one complete start tag.
    max_start_tag_bytes: usize = 1024 * 1024,
    /// Maximum bytes exposed by one fragmented semantic event.
    max_fragment_bytes: usize = 64 * 1024,
    /// Maximum UTF-8 bytes accepted in one processing-instruction target.
    max_processing_instruction_target_bytes: usize = 64 * 1024,
    /// Maximum owned capacity retained across a retain reset.
    max_retained_bytes: usize = 1024 * 1024,

    fn validate(self: Limits) bool {
        return self.max_depth > 0 and
            self.max_open_name_bytes > 0 and
            self.max_partial_token_bytes > 0 and
            self.max_attributes_per_element > 0 and
            self.max_attribute_name_bytes > 0 and
            self.max_attribute_value_bytes > 0 and
            self.max_attribute_bytes_per_element > 0 and
            self.max_start_tag_bytes > 0 and
            self.max_fragment_bytes > 0 and
            self.max_processing_instruction_target_bytes > 0;
    }
};

/// Namespace limits specialized out of namespace-off reader options.
pub fn NamespaceLimits(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            /// Maximum namespace declarations accepted on one element.
            max_declarations_per_element: usize = 64,
            /// Maximum active namespace bindings, including shadowed bindings.
            max_active_bindings: usize = 1024,
            /// Maximum bytes retained by active namespace bindings.
            max_binding_bytes: usize = 1024 * 1024,
            /// Maximum UTF-8 bytes accepted in one qualified name.
            max_qname_bytes: usize = 64 * 1024,
            /// Maximum weighted prefix and expanded-name comparison work per start element.
            max_comparison_work: usize = 1024 * 1024,

            fn validate(self: @This()) bool {
                return self.max_declarations_per_element > 0 and
                    self.max_active_bindings > 0 and
                    self.max_binding_bytes > 0 and
                    self.max_qname_bytes > 0 and
                    self.max_comparison_work > 0;
            }
        }
    else
        struct {
            fn validate(_: @This()) bool {
                return true;
            }
        };
}

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
    /// Source attributes retained for the current start element.
    attribute_count: usize = 0,
    /// Reusable source-attribute record capacity measured in slots.
    attribute_record_capacity: usize = 0,
    /// Reusable public-attribute capacity measured in slots.
    attribute_event_capacity: usize = 0,
    /// Active attribute name and value bytes.
    attribute_bytes: usize = 0,
    /// Active reusable scratch bytes, including attributes and markup targets.
    scratch_bytes: usize = 0,
    /// Reusable attribute and markup scratch capacity measured in bytes.
    scratch_capacity: usize = 0,
    /// Namespace storage capacity measured in bytes.
    namespace_capacity: usize = 0,
    /// Active namespace bindings, including shadowed bindings.
    namespace_binding_count: usize = 0,
    /// Active bytes retained by namespace bindings.
    namespace_bytes: usize = 0,
    /// DTD storage capacity measured in bytes.
    dtd_capacity: usize = 0,
    /// Validation storage capacity measured in bytes.
    validation_capacity: usize = 0,
    /// Total reader-owned reusable capacity measured in bytes.
    retained_capacity: usize = 0,
};

/// Stable diagnostic category for the current reader API.
pub const DiagnosticCode = enum {
    invalid_state,
    unsupported_stage,
    empty_document,
    unexpected_document_text,
    malformed_start_tag,
    malformed_attribute,
    attribute_less_than,
    duplicate_attribute,
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
    attribute_count_limit,
    attribute_name_limit,
    attribute_value_limit,
    attribute_bytes_limit,
    start_tag_limit,
    fragment_limit,
    malformed_utf8,
    forbidden_character,
    malformed_reference,
    invalid_character_reference,
    undeclared_entity,
    cdata_close_in_text,
    malformed_declaration,
    incomplete_declaration,
    unsupported_version,
    unsupported_encoding,
    misplaced_xml_declaration,
    reserved_processing_instruction_target,
    malformed_processing_instruction,
    incomplete_processing_instruction,
    processing_instruction_target_limit,
    malformed_qname,
    malformed_ncname,
    illegal_namespace_declaration,
    reserved_namespace_name,
    unbound_prefix,
    duplicate_expanded_attribute,
    namespace_declaration_limit,
    namespace_binding_limit,
    namespace_binding_bytes_limit,
    qname_limit,
    namespace_comparison_limit,
    malformed_comment,
    unclosed_comment,
    malformed_cdata,
    unclosed_cdata,
    malformed_markup_declaration,
    misplaced_doctype,
    unsupported_doctype,
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
        namespace_limits: NamespaceLimits(config) = .{},
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

/// Element or attribute name specialized to the selected namespace profile.
pub fn Name(comptime config: Config) type {
    return if (config.profile.hasNamespaces()) ExpandedName else RawName;
}

/// Source attribute whose slices follow the enclosing event lifetime.
pub fn Attribute(comptime config: Config) type {
    return struct {
        name: Name(config),
        value: []const u8,
    };
}

/// One source-ordered namespace declaration whose slices follow the event lifetime.
pub const NamespaceDeclaration = struct {
    prefix: ?[]const u8,
    namespace_uri: []const u8,
};

fn StartElement(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            name: Name(config),
            attributes: []const Attribute(config),
            namespace_declarations: []const NamespaceDeclaration,
            empty_element_syntax: bool,
        }
    else
        struct {
            name: Name(config),
            attributes: []const Attribute(config),
            empty_element_syntax: bool,
        };
}

fn EndElement(comptime config: Config) type {
    return struct {
        name: Name(config),
    };
}

/// XML rules selected for a document entity.
pub const XmlVersion = enum {
    xml10,
};

/// Source encoding detected by the UTF-8-only profile.
pub const SourceEncoding = enum {
    utf8,
};

/// Origin of one text fragment.
pub const TextOrigin = enum {
    character_data,
    cdata,
};

const DocumentStart = struct {
    effective_version: XmlVersion = .xml10,
    declared_version: ?[]const u8 = null,
    source_encoding: SourceEncoding = .utf8,
    declared_encoding: ?[]const u8 = null,
    standalone: bool = false,
    standalone_declared: bool = false,
};
const DocumentEnd = struct {};
const DocumentType = struct {
    root_name: []const u8,
};
const Text = struct {
    bytes: []const u8,
    origin: TextOrigin = .character_data,
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
    detect_bom,
    document_start_probe,
    initial_markup,
    emit_document_start,
    release_document_start,
    before_root,
    before_root_markup,
    content,
    content_after_carriage_return,
    content_markup,
    after_root,
    after_root_markup,
    start_name,
    start_after_space,
    attribute_name,
    attribute_after_name,
    attribute_before_value,
    attribute_value,
    attribute_after_carriage_return,
    start_after_attribute,
    empty_slash,
    emit_start_element,
    emit_empty_start_element,
    release_start_attributes,
    release_empty_attributes,
    emit_end_element,
    end_expect_name,
    end_name,
    end_after_space,
    release_closed_element,
    reference_start,
    reference_numeric_prefix,
    reference_numeric,
    reference_entity,
    emit_text,
    release_text,
    markup_declaration_start,
    comment_open,
    comment,
    comment_after_carriage_return,
    emit_comment,
    release_comment,
    cdata_open,
    cdata,
    cdata_after_carriage_return,
    doctype_open,
    processing_instruction_target,
    processing_instruction_after_target,
    processing_instruction_before_data,
    processing_instruction,
    processing_instruction_after_carriage_return,
    emit_processing_instruction,
    release_processing_instruction,
    declaration,
    declaration_question,
    emit_document_end,
    complete,
};

const MarkupContext = enum {
    prolog,
    content,
    epilog,
};

const ReferenceContext = enum {
    content,
    attribute,
};

const ReferenceKind = enum {
    decimal,
    hexadecimal,
};

const ScalarSource = enum {
    ordinary,
    start_tag,
    reference,
};

const DecodedScalar = struct {
    codepoint: u21,
    len: u3,
};

const Utf8Probe = union(enum) {
    scalar: DecodedScalar,
    incomplete,
    invalid: usize,
};

const NamespaceBinding = struct {
    prefix_offset: usize,
    prefix_len: usize,
    uri_offset: usize,
    uri_len: usize,
    previous_binding: ?usize,
    active_index: usize,
};

const NamespaceReference = union(enum) {
    none,
    predefined_xml,
    binding: usize,
};

const QNameParts = struct {
    prefix: ?[]const u8,
    local: []const u8,
};

const xml_namespace_uri = "http://www.w3.org/XML/1998/namespace";
const xmlns_namespace_uri = "http://www.w3.org/2000/xmlns/";

fn NamespaceState(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            bindings: std.ArrayList(NamespaceBinding) = .empty,
            active_prefixes: std.ArrayList(usize) = .empty,
            bytes: std.ArrayList(u8) = .empty,
            event_declarations: std.ArrayList(NamespaceDeclaration) = .empty,
            expanded_indices: std.ArrayList(usize) = .empty,
            event_attribute_locations: std.ArrayList(Location(config)) = .empty,
            comparison_work: usize = 0,
            reference_colon: ?Location(config) = null,
        }
    else
        struct {};
}

fn OpenElementFrame(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            name_offset: usize,
            name_len: usize,
            start: Location(config),
            namespace_binding_mark: usize,
            namespace_byte_mark: usize,
            namespace_reference: NamespaceReference,
        }
    else
        struct {
            name_offset: usize,
            name_len: usize,
            start: Location(config),
        };
}

fn AttributeRecord(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            name_offset: usize,
            name_len: usize,
            value_len: usize,
            start: Location(config),
            namespace_shape: usize = 0,
        }
    else
        struct {
            name_offset: usize,
            name_len: usize,
            value_len: usize,
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
        const linear_duplicate_threshold = 64;

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
        vertical_state: VerticalState = .detect_bom,
        failure: ?Failure = null,
        open_elements: std.ArrayList(OpenElementFrame(config)) = .empty,
        open_names: std.ArrayList(u8) = .empty,
        attribute_records: std.ArrayList(AttributeRecord(config)) = .empty,
        attribute_bytes: std.ArrayList(u8) = .empty,
        event_attributes: std.ArrayList(Attribute(config)) = .empty,
        namespace_state: NamespaceState(config) = .{},
        token_start: Location(config) = .{},
        token_name_len: usize = 0,
        end_mismatch_index: usize = no_end_mismatch,
        attribute_quote: u8 = 0,
        utf8_bytes: [4]u8 = @splat(0),
        utf8_len: u3 = 0,
        utf8_expected_len: u3 = 0,
        utf8_start: Location(config) = .{},
        text_inline: [4]u8 = @splat(0),
        text_fragment: []const u8 = &.{},
        text_start: Location(config) = .{},
        text_close_brackets: u2 = 0,
        reference_context: ReferenceContext = .content,
        reference_kind: ReferenceKind = .decimal,
        reference_start: Location(config) = .{},
        reference_value: u32 = 0,
        reference_has_digits: bool = false,
        reference_token_bytes: usize = 0,
        reference_name: [5]u8 = @splat(0),
        reference_name_len: usize = 0,
        document_start_resume: VerticalState = .before_root,
        document_start_span: Location(config) = .{},
        declared_version_offset: usize = 0,
        declared_version_len: usize = 0,
        declared_encoding_offset: usize = 0,
        declared_encoding_len: usize = 0,
        standalone: bool = false,
        standalone_declared: bool = false,
        markup_context: MarkupContext = .prolog,
        delimiter_index: usize = 0,
        delimiter_bytes: [2]u8 = @splat(0),
        delimiter_len: u2 = 0,
        delimiter_start: Location(config) = .{},
        fragment_complete: bool = false,
        text_origin: TextOrigin = .character_data,
        text_resume: VerticalState = .content,
        processing_instruction_initial: bool = false,
        processing_instruction_target_len: usize = 0,
        declaration_data_start: Location(config) = .{},

        /// Initializes a reader without allocating.
        pub fn init(allocator: std.mem.Allocator, options: Options(config)) InitError!Self {
            if (!options.limits.validate() or !options.namespace_limits.validate()) {
                return error.InvalidOptions;
            }
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
                        self.clearAttributesRetainingCapacity();
                        self.clearNamespacesRetainingCapacity();
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
            self.vertical_state = .detect_bom;
            self.failure = null;
            self.token_start = .{};
            self.token_name_len = 0;
            self.end_mismatch_index = no_end_mismatch;
            self.attribute_quote = 0;
            self.utf8_bytes = @splat(0);
            self.utf8_len = 0;
            self.utf8_expected_len = 0;
            self.utf8_start = .{};
            self.text_inline = @splat(0);
            self.text_fragment = &.{};
            self.text_start = .{};
            self.text_close_brackets = 0;
            self.reference_context = .content;
            self.reference_kind = .decimal;
            self.reference_start = .{};
            self.reference_value = 0;
            self.reference_has_digits = false;
            self.reference_token_bytes = 0;
            self.reference_name = @splat(0);
            self.reference_name_len = 0;
            self.document_start_resume = .before_root;
            self.document_start_span = .{};
            self.declared_version_offset = 0;
            self.declared_version_len = 0;
            self.declared_encoding_offset = 0;
            self.declared_encoding_len = 0;
            self.standalone = false;
            self.standalone_declared = false;
            self.markup_context = .prolog;
            self.delimiter_index = 0;
            self.delimiter_bytes = @splat(0);
            self.delimiter_len = 0;
            self.delimiter_start = .{};
            self.fragment_complete = false;
            self.text_origin = .character_data;
            self.text_resume = .content;
            self.processing_instruction_initial = false;
            self.processing_instruction_target_len = 0;
            self.declaration_data_start = .{};
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
            if (comptime config.profile != .xml10_utf8_no_dtd and
                config.profile != .xml10_utf8_ns_no_dtd)
            {
                return self.fail(.unsupported_stage, .unsupported_feature);
            }

            while (true) {
                switch (self.vertical_state) {
                    .detect_bom => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            self.clearUtf8Scalar();
                            if (scalar.codepoint == 0xfeff) {
                                self.vertical_state = .document_start_probe;
                                continue;
                            }
                            return self.failAt(.unexpected_document_text, .invalid_xml, start);
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                self.vertical_state = .document_start_probe;
                                continue;
                            }
                            return self.needInput();
                        }
                        if (self.utf8_len == 0 and self.input[self.cursor] < 0x80) {
                            self.vertical_state = .document_start_probe;
                            continue;
                        }
                        const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                            return self.needInput();
                        const start = self.utf8_start;
                        if (!isXml10Char(scalar.codepoint)) {
                            return self.failAt(.forbidden_character, .invalid_xml, start);
                        }
                        self.clearUtf8Scalar();
                        if (scalar.codepoint == 0xfeff) {
                            self.vertical_state = .document_start_probe;
                            continue;
                        }
                        return self.failAt(.unexpected_document_text, .invalid_xml, start);
                    },
                    .document_start_probe => {
                        if (self.cursor == self.input.len) {
                            if (!self.final_input) return self.needInput();
                            self.document_start_span = self.currentLocation();
                            self.document_start_resume = .before_root;
                            self.vertical_state = .emit_document_start;
                            continue;
                        }
                        if (self.input[self.cursor] != '<') {
                            self.document_start_span = self.currentLocation();
                            self.document_start_resume = .before_root;
                            self.vertical_state = .emit_document_start;
                            continue;
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .initial_markup;
                    },
                    .initial_markup => {
                        if (self.cursor == self.input.len) {
                            if (!self.final_input) return self.needInput();
                            self.document_start_span = self.token_start;
                            self.document_start_resume = .before_root_markup;
                            self.vertical_state = .emit_document_start;
                            continue;
                        }
                        if (self.input[self.cursor] == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.prolog, true);
                            continue;
                        }
                        self.document_start_span = self.token_start;
                        self.document_start_resume = .before_root_markup;
                        self.vertical_state = .emit_document_start;
                    },
                    .emit_document_start => {
                        self.vertical_state = self.document_start_resume;
                        const end = self.currentLocation();
                        return self.eventStep(
                            .{ .document_start = self.documentStart() },
                            self.document_start_span,
                            end,
                        );
                    },
                    .release_document_start => {
                        self.clearAttributesRetainingCapacity();
                        self.vertical_state = .before_root;
                    },
                    .before_root => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            return self.failAt(
                                .unexpected_document_text,
                                .invalid_xml,
                                start,
                            );
                        }
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.empty_document, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '<') {
                            const byte = self.input[self.cursor];
                            if (byte >= 0x80) {
                                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                    return self.needInput();
                                const start = self.utf8_start;
                                if (!isXml10Char(scalar.codepoint)) {
                                    return self.failAt(
                                        .forbidden_character,
                                        .invalid_xml,
                                        start,
                                    );
                                }
                                return self.failAt(
                                    .unexpected_document_text,
                                    .invalid_xml,
                                    start,
                                );
                            }
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
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
                        if (byte == '!') {
                            self.consumeByte('!');
                            self.beginMarkupDeclaration(.prolog);
                            continue;
                        }
                        if (byte == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.prolog, false);
                            continue;
                        }
                        if (byte == '/') {
                            return self.fail(.unexpected_end_tag, .invalid_xml);
                        }
                        if (byte >= 0x80 or isAsciiNameStart(byte)) {
                            try self.beginStartElement();
                            continue;
                        }
                        if (!isXml10Char(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        if (!isAsciiNameStart(byte)) {
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                    },
                    .content => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            self.text_close_brackets = 0;
                            try self.prepareInlineText(
                                self.utf8_bytes[0..scalar.len],
                                start,
                            );
                            self.clearUtf8Scalar();
                            continue;
                        }
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
                        const byte = self.input[self.cursor];
                        if (byte == '<') {
                            self.text_close_brackets = 0;
                            self.token_start = self.currentLocation();
                            self.consumeByte('<');
                            self.vertical_state = .content_markup;
                            continue;
                        }
                        if (byte == '&') {
                            self.text_close_brackets = 0;
                            if (try self.prepareCompleteContentReference()) continue;
                            try self.beginReference(.content);
                            continue;
                        }
                        if (byte == '\r') {
                            self.text_close_brackets = 0;
                            self.text_start = self.currentLocation();
                            self.consumeByte(byte);
                            self.vertical_state = .content_after_carriage_return;
                            continue;
                        }
                        if (try self.prepareContentRun()) continue;
                        const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                            return self.needInput();
                        const start = self.utf8_start;
                        if (!isXml10Char(scalar.codepoint)) {
                            return self.failAt(.forbidden_character, .invalid_xml, start);
                        }
                        self.text_close_brackets = 0;
                        try self.prepareInlineText(
                            self.utf8_bytes[0..scalar.len],
                            start,
                        );
                        self.clearUtf8Scalar();
                    },
                    .content_after_carriage_return => {
                        if (self.cursor == self.input.len and !self.final_input) {
                            return self.needInput();
                        }
                        if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                            self.consumeByte('\n');
                        }
                        try self.prepareInlineText(
                            "\n",
                            self.text_start,
                        );
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
                        if (byte == '!') {
                            self.consumeByte('!');
                            self.beginMarkupDeclaration(.content);
                            continue;
                        }
                        if (byte == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.content, false);
                            continue;
                        }
                        if (byte >= 0x80 or isAsciiNameStart(byte)) {
                            try self.beginStartElement();
                            continue;
                        }
                        if (!isXml10Char(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        if (!isAsciiNameStart(byte)) {
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                    },
                    .after_root => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            return self.failAt(.trailing_content, .invalid_xml, start);
                        }
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                self.vertical_state = .emit_document_end;
                                continue;
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '<') {
                            const byte = self.input[self.cursor];
                            if (byte >= 0x80) {
                                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                    return self.needInput();
                                const start = self.utf8_start;
                                if (!isXml10Char(scalar.codepoint)) {
                                    return self.failAt(
                                        .forbidden_character,
                                        .invalid_xml,
                                        start,
                                    );
                                }
                                return self.failAt(.trailing_content, .invalid_xml, start);
                            }
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.trailing_content, .invalid_xml);
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .after_root_markup;
                    },
                    .after_root_markup => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            if (isXml10NameStart(scalar.codepoint)) {
                                return self.failAt(
                                    .multiple_document_elements,
                                    .invalid_xml,
                                    self.token_start,
                                );
                            }
                            return self.failAt(.trailing_content, .invalid_xml, start);
                        }
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
                        if (byte == '!') {
                            self.consumeByte('!');
                            self.beginMarkupDeclaration(.epilog);
                            continue;
                        }
                        if (byte == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.epilog, false);
                            continue;
                        }
                        if (byte >= 0x80) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            if (isXml10NameStart(scalar.codepoint)) {
                                return self.failAt(
                                    .multiple_document_elements,
                                    .invalid_xml,
                                    self.token_start,
                                );
                            }
                            return self.failAt(.trailing_content, .invalid_xml, start);
                        }
                        if (isAsciiNameStart(byte)) {
                            return self.failAt(
                                .multiple_document_elements,
                                .invalid_xml,
                                self.token_start,
                            );
                        }
                        if (!isXml10Char(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        return self.fail(.trailing_content, .invalid_xml);
                    },
                    .start_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (self.utf8_len == 0 and run_end < self.input.len and
                            isAsciiNameChar(self.input[run_end]))
                        {
                            run_end += 1;
                        }
                        try self.appendStartNameRun(self.input[run_start..run_end]);

                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            try self.ensureStartNameScalarCapacity();
                            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                return self.needInput();
                            const scalar_start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(
                                    .forbidden_character,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            const valid = if (self.token_name_len == 0)
                                isXml10NameStart(scalar.codepoint)
                            else
                                isXml10NameChar(scalar.codepoint);
                            if (!valid) {
                                return self.failAt(
                                    .malformed_start_tag,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            try self.appendDecodedStartName(scalar.len);
                            self.clearUtf8Scalar();
                            continue;
                        }

                        if (self.cursor < self.input.len) {
                            try self.requireStartTagByte();
                            const byte = self.input[self.cursor];
                            if (byte == '/') {
                                self.consumeStartTagByte(byte);
                                self.vertical_state = .empty_slash;
                                continue;
                            }
                            if (byte == '>') {
                                self.consumeStartTagByte(byte);
                                try self.finishStartElement(false);
                                continue;
                            }
                            if (isXmlWhitespace(byte)) {
                                self.vertical_state = .start_after_space;
                                continue;
                            }
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .start_after_space => {
                        try self.consumeStartTagWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        const byte = self.input[self.cursor];
                        if (byte == '>') {
                            self.consumeStartTagByte(byte);
                            try self.finishStartElement(false);
                            continue;
                        }
                        if (byte == '/') {
                            self.consumeStartTagByte(byte);
                            self.vertical_state = .empty_slash;
                            continue;
                        }
                        if (byte >= 0x80 or isAsciiNameStart(byte)) {
                            try self.beginAttribute();
                            continue;
                        }
                        if (!isXml10Char(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        return self.fail(.malformed_attribute, .invalid_xml);
                    },
                    .attribute_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (self.utf8_len == 0 and run_end < self.input.len and
                            isAsciiNameChar(self.input[run_end]))
                        {
                            run_end += 1;
                        }
                        try self.appendAttributeNameRun(self.input[run_start..run_end]);

                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            try self.ensureAttributeNameScalarCapacity();
                            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                return self.needInput();
                            const scalar_start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(
                                    .forbidden_character,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            const record = self.attribute_records.items[
                                self.attribute_records.items.len - 1
                            ];
                            const valid = if (record.name_len == 0)
                                isXml10NameStart(scalar.codepoint)
                            else
                                isXml10NameChar(scalar.codepoint);
                            if (!valid) {
                                return self.failAt(
                                    .malformed_attribute,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            try self.appendDecodedAttributeName(scalar.len);
                            self.clearUtf8Scalar();
                            continue;
                        }

                        if (self.cursor < self.input.len) {
                            try self.requireStartTagByte();
                            const byte = self.input[self.cursor];
                            if (byte == '=') {
                                self.consumeStartTagByte(byte);
                                self.vertical_state = .attribute_before_value;
                                continue;
                            }
                            if (isXmlWhitespace(byte)) {
                                self.vertical_state = .attribute_after_name;
                                continue;
                            }
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .attribute_after_name => {
                        try self.consumeStartTagWhitespaceRun();
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_attribute)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        if (self.input[self.cursor] != '=') {
                            if (!isXml10Char(self.input[self.cursor])) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        self.consumeStartTagByte('=');
                        self.vertical_state = .attribute_before_value;
                    },
                    .attribute_before_value => {
                        try self.consumeStartTagWhitespaceRun();
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_attribute)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        const byte = self.input[self.cursor];
                        if (byte != '\'' and byte != '"') {
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        self.attribute_quote = byte;
                        self.consumeStartTagByte(byte);
                        self.vertical_state = .attribute_value;
                    },
                    .attribute_value => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            try self.appendAttributeOutput(self.utf8_bytes[0..scalar.len]);
                            self.clearUtf8Scalar();
                            continue;
                        }
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (run_end < self.input.len and
                            isOrdinaryAttributeValueByte(self.input[run_end], self.attribute_quote))
                        {
                            run_end += 1;
                        }
                        try self.appendAttributeValueRun(self.input[run_start..run_end]);

                        if (self.cursor < self.input.len) {
                            try self.requireStartTagByte();
                            const byte = self.input[self.cursor];
                            if (byte == self.attribute_quote) {
                                self.consumeStartTagByte(byte);
                                self.finishAttribute();
                                self.vertical_state = .start_after_attribute;
                                continue;
                            }
                            if (byte == '<') {
                                return self.fail(.attribute_less_than, .invalid_xml);
                            }
                            if (byte == '&') {
                                try self.beginReference(.attribute);
                                continue;
                            }
                            if (byte == '\r') {
                                self.consumeStartTagByte(byte);
                                self.vertical_state = .attribute_after_carriage_return;
                                continue;
                            }
                            if (byte == '\n' or byte == '\t') {
                                self.consumeStartTagByte(byte);
                                try self.appendAttributeOutput(" ");
                                continue;
                            }
                            if (byte >= 0x80) {
                                try self.ensureAttributeValueScalarCapacity();
                                const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                    return self.needInput();
                                const start = self.utf8_start;
                                if (!isXml10Char(scalar.codepoint)) {
                                    return self.failAt(
                                        .forbidden_character,
                                        .invalid_xml,
                                        start,
                                    );
                                }
                                try self.appendAttributeOutput(
                                    self.utf8_bytes[0..scalar.len],
                                );
                                self.clearUtf8Scalar();
                                continue;
                            }
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .attribute_after_carriage_return => {
                        if (self.cursor == self.input.len and !self.final_input) {
                            return self.needInput();
                        }
                        if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                            try self.requireStartTagByte();
                            self.consumeStartTagByte('\n');
                        }
                        try self.appendAttributeOutput(" ");
                        self.vertical_state = .attribute_value;
                    },
                    .start_after_attribute => {
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_attribute)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        const byte = self.input[self.cursor];
                        if (byte == '>') {
                            self.consumeStartTagByte(byte);
                            try self.finishStartElement(false);
                            continue;
                        }
                        if (byte == '/') {
                            self.consumeStartTagByte(byte);
                            self.vertical_state = .empty_slash;
                            continue;
                        }
                        if (isXmlWhitespace(byte)) {
                            self.vertical_state = .start_after_space;
                            continue;
                        }
                        if (!isXml10Char(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        return self.fail(.malformed_attribute, .invalid_xml);
                    },
                    .empty_slash => {
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_start_tag)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        if (self.input[self.cursor] != '>') {
                            if (!isXml10Char(self.input[self.cursor])) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        self.consumeStartTagByte('>');
                        try self.finishStartElement(true);
                    },
                    .emit_start_element => {
                        self.vertical_state = .release_start_attributes;
                        return self.eventStep(
                            .{ .start_element = self.startElement(false) },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .emit_empty_start_element => {
                        self.vertical_state = .release_empty_attributes;
                        return self.eventStep(
                            .{ .start_element = self.startElement(true) },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .release_start_attributes => {
                        self.clearAttributesRetainingCapacity();
                        self.vertical_state = .content;
                    },
                    .release_empty_attributes => {
                        self.clearAttributesRetainingCapacity();
                        self.vertical_state = .emit_end_element;
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
                        const byte = self.input[self.cursor];
                        if (byte < 0x80 and !isAsciiNameStart(byte)) {
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_end_tag, .invalid_xml);
                        }
                        self.token_name_len = 0;
                        self.end_mismatch_index = no_end_mismatch;
                        self.vertical_state = .end_name;
                    },
                    .end_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (self.utf8_len == 0 and run_end < self.input.len and
                            isAsciiNameChar(self.input[run_end]))
                        {
                            run_end += 1;
                        }
                        try self.compareAndConsumeEndName(self.input[run_start..run_end]);

                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            const scalar_start = if (self.utf8_len == 0)
                                self.currentLocation()
                            else
                                self.utf8_start;
                            const scalar_len = self.pendingUtf8ScalarLength() catch
                                return self.fail(.malformed_utf8, .invalid_xml);
                            if (scalar_len > self.options.limits.max_partial_token_bytes -
                                self.token_name_len)
                            {
                                return self.failVoid(.partial_token_limit, .limit_exceeded);
                            }
                            if (scalar_len > self.qnameRemaining(self.token_name_len)) {
                                return self.failVoid(.qname_limit, .limit_exceeded);
                            }
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            if (!isXml10Char(scalar.codepoint)) {
                                return self.failAt(
                                    .forbidden_character,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            const valid = if (self.token_name_len == 0)
                                isXml10NameStart(scalar.codepoint)
                            else
                                isXml10NameChar(scalar.codepoint);
                            if (!valid) {
                                return self.failAt(
                                    .malformed_end_tag,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            try self.compareDecodedEndName(scalar.len);
                            self.clearUtf8Scalar();
                            continue;
                        }

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
                            if (!isXml10Char(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
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
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectNonAsciiMarkup(.malformed_end_tag)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '>') {
                            if (!isXml10Char(self.input[self.cursor])) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
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
                    .reference_start => if (try self.readReferenceStart()) {
                        return self.needInput();
                    },
                    .reference_numeric_prefix => if (try self.readReferenceNumericPrefix()) {
                        return self.needInput();
                    },
                    .reference_numeric => if (try self.readReferenceNumeric()) {
                        return self.needInput();
                    },
                    .reference_entity => if (try self.readReferenceEntity()) {
                        return self.needInput();
                    },
                    .emit_text => {
                        self.vertical_state = .release_text;
                        return self.eventStep(
                            .{ .text = .{
                                .bytes = self.text_fragment,
                                .origin = self.text_origin,
                            } },
                            self.text_start,
                            self.currentLocation(),
                        );
                    },
                    .release_text => {
                        self.text_fragment = &.{};
                        self.vertical_state = self.text_resume;
                    },
                    .markup_declaration_start => if (try self.readMarkupDeclarationStart()) {
                        return self.needInput();
                    },
                    .comment_open => if (try self.readFixedDelimiter("--", .malformed_comment)) {
                        self.vertical_state = .comment;
                    } else return self.needInput(),
                    .comment => if (try self.readComment()) return self.needInput(),
                    .comment_after_carriage_return => if (try self.readCommentCarriageReturn()) {
                        return self.needInput();
                    },
                    .emit_comment => {
                        self.vertical_state = .release_comment;
                        return self.eventStep(
                            .{ .comment = .{
                                .bytes = self.text_fragment,
                                .complete = self.fragment_complete,
                            } },
                            self.text_start,
                            self.currentLocation(),
                        );
                    },
                    .release_comment => {
                        self.text_fragment = &.{};
                        self.vertical_state = if (self.fragment_complete)
                            self.contextResumeState()
                        else
                            .comment;
                    },
                    .cdata_open => if (try self.readFixedDelimiter(
                        "[CDATA[",
                        .malformed_cdata,
                    )) {
                        if (self.markup_context != .content) {
                            return self.failAt(.malformed_cdata, .invalid_xml, self.token_start);
                        }
                        self.vertical_state = .cdata;
                    } else return self.needInput(),
                    .cdata => if (try self.readCdata()) return self.needInput(),
                    .cdata_after_carriage_return => if (try self.readCdataCarriageReturn()) {
                        return self.needInput();
                    },
                    .doctype_open => if (try self.readFixedDelimiter(
                        "DOCTYPE",
                        .malformed_markup_declaration,
                    )) {
                        if (self.markup_context == .prolog) {
                            return self.failAt(
                                .unsupported_doctype,
                                .unsupported_feature,
                                self.token_start,
                            );
                        }
                        return self.failAt(.misplaced_doctype, .invalid_xml, self.token_start);
                    } else return self.needInput(),
                    .processing_instruction_target => if (try self.readProcessingInstructionTarget()) {
                        return self.needInput();
                    },
                    .processing_instruction_after_target => if (try self.readProcessingInstructionAfterTarget()) {
                        return self.needInput();
                    },
                    .processing_instruction_before_data => if (try self.readProcessingInstructionBeforeData()) {
                        return self.needInput();
                    },
                    .processing_instruction => if (try self.readProcessingInstruction()) {
                        return self.needInput();
                    },
                    .processing_instruction_after_carriage_return => if (try self.readProcessingInstructionCarriageReturn()) {
                        return self.needInput();
                    },
                    .emit_processing_instruction => {
                        self.vertical_state = .release_processing_instruction;
                        return self.eventStep(
                            .{ .processing_instruction = .{
                                .target = self.processingInstructionTarget(),
                                .data = self.text_fragment,
                                .complete = self.fragment_complete,
                            } },
                            self.text_start,
                            self.currentLocation(),
                        );
                    },
                    .release_processing_instruction => {
                        self.text_fragment = &.{};
                        if (self.fragment_complete) {
                            self.clearAttributesRetainingCapacity();
                            self.vertical_state = self.contextResumeState();
                        } else {
                            self.vertical_state = .processing_instruction;
                        }
                    },
                    .declaration => if (try self.readDeclaration()) return self.needInput(),
                    .declaration_question => if (try self.readDeclarationQuestion()) {
                        return self.needInput();
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
                .attribute_count = self.attribute_records.items.len,
                .attribute_record_capacity = self.attribute_records.capacity,
                .attribute_event_capacity = self.event_attributes.capacity,
                .attribute_bytes = if (self.attribute_records.items.len == 0)
                    0
                else
                    self.attribute_bytes.items.len,
                .scratch_bytes = self.attribute_bytes.items.len,
                .scratch_capacity = self.attribute_bytes.capacity,
                .namespace_capacity = self.namespaceCapacity(),
                .namespace_binding_count = self.namespaceBindingCount(),
                .namespace_bytes = self.namespaceBytes(),
                .retained_capacity = self.retainedCapacity(),
            };
        }

        fn retainedCapacity(self: *const Self) usize {
            const stack_bytes = self.open_elements.capacity *| @sizeOf(OpenElementFrame(config));
            const record_bytes = self.attribute_records.capacity *| @sizeOf(AttributeRecord(config));
            const event_bytes = self.event_attributes.capacity *| @sizeOf(Attribute(config));
            return stack_bytes +|
                self.open_names.capacity +|
                record_bytes +|
                self.attribute_bytes.capacity +|
                event_bytes +|
                self.namespaceCapacity();
        }

        fn namespaceCapacity(self: *const Self) usize {
            if (comptime !config.profile.hasNamespaces()) return 0;
            return self.namespace_state.bindings.capacity *| @sizeOf(NamespaceBinding) +|
                self.namespace_state.active_prefixes.capacity *| @sizeOf(usize) +|
                self.namespace_state.bytes.capacity +|
                self.namespace_state.event_declarations.capacity *| @sizeOf(NamespaceDeclaration) +|
                self.namespace_state.expanded_indices.capacity *| @sizeOf(usize) +|
                self.namespace_state.event_attribute_locations.capacity *| @sizeOf(Location(config));
        }

        fn namespaceBindingCount(self: *const Self) usize {
            if (comptime !config.profile.hasNamespaces()) return 0;
            return self.namespace_state.bindings.items.len;
        }

        fn namespaceBytes(self: *const Self) usize {
            if (comptime !config.profile.hasNamespaces()) return 0;
            return self.namespace_state.bytes.items.len;
        }

        fn releaseStorage(self: *Self) void {
            self.open_elements.deinit(self.allocator);
            self.open_names.deinit(self.allocator);
            self.attribute_records.deinit(self.allocator);
            self.attribute_bytes.deinit(self.allocator);
            self.event_attributes.deinit(self.allocator);
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.bindings.deinit(self.allocator);
                self.namespace_state.active_prefixes.deinit(self.allocator);
                self.namespace_state.bytes.deinit(self.allocator);
                self.namespace_state.event_declarations.deinit(self.allocator);
                self.namespace_state.expanded_indices.deinit(self.allocator);
                self.namespace_state.event_attribute_locations.deinit(self.allocator);
            }
            self.open_elements = .empty;
            self.open_names = .empty;
            self.attribute_records = .empty;
            self.attribute_bytes = .empty;
            self.event_attributes = .empty;
            self.namespace_state = .{};
        }

        fn clearAttributesRetainingCapacity(self: *Self) void {
            self.attribute_records.clearRetainingCapacity();
            self.attribute_bytes.clearRetainingCapacity();
            self.event_attributes.clearRetainingCapacity();
            self.attribute_quote = 0;
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.event_declarations.clearRetainingCapacity();
                self.namespace_state.expanded_indices.clearRetainingCapacity();
                self.namespace_state.event_attribute_locations.clearRetainingCapacity();
                self.namespace_state.comparison_work = 0;
                self.namespace_state.reference_colon = null;
            }
        }

        fn clearNamespacesRetainingCapacity(self: *Self) void {
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.bindings.clearRetainingCapacity();
                self.namespace_state.active_prefixes.clearRetainingCapacity();
                self.namespace_state.bytes.clearRetainingCapacity();
                self.namespace_state.event_declarations.clearRetainingCapacity();
                self.namespace_state.expanded_indices.clearRetainingCapacity();
                self.namespace_state.event_attribute_locations.clearRetainingCapacity();
                self.namespace_state.comparison_work = 0;
                self.namespace_state.reference_colon = null;
            }
        }

        fn documentStart(self: *const Self) DocumentStart {
            const bytes = self.attribute_bytes.items;
            return .{
                .declared_version = if (self.declared_version_len == 0)
                    null
                else
                    bytes[self.declared_version_offset..][0..self.declared_version_len],
                .declared_encoding = if (self.declared_encoding_len == 0)
                    null
                else
                    bytes[self.declared_encoding_offset..][0..self.declared_encoding_len],
                .standalone = self.standalone,
                .standalone_declared = self.standalone_declared,
            };
        }

        fn contextResumeState(self: *const Self) VerticalState {
            return switch (self.markup_context) {
                .prolog => .before_root,
                .content => .content,
                .epilog => .after_root,
            };
        }

        fn beginMarkupDeclaration(self: *Self, context: MarkupContext) void {
            self.markup_context = context;
            self.delimiter_index = 0;
            self.delimiter_len = 0;
            self.vertical_state = .markup_declaration_start;
        }

        fn readMarkupDeclarationStart(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                return self.failAt(
                    .malformed_markup_declaration,
                    .invalid_xml,
                    start,
                );
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.incomplete_input, .invalid_xml);
                return true;
            }
            switch (self.input[self.cursor]) {
                '-' => self.vertical_state = .comment_open,
                '[' => self.vertical_state = .cdata_open,
                'D' => self.vertical_state = .doctype_open,
                else => {
                    if (self.input[self.cursor] >= 0x80) {
                        const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                        const start = self.utf8_start;
                        if (!isXml10Char(scalar.codepoint)) {
                            return self.failAt(.forbidden_character, .invalid_xml, start);
                        }
                        return self.failAt(
                            .malformed_markup_declaration,
                            .invalid_xml,
                            start,
                        );
                    }
                    if (!isXml10Char(self.input[self.cursor])) {
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                    return self.failVoid(.malformed_markup_declaration, .invalid_xml);
                },
            }
            return false;
        }

        fn readFixedDelimiter(
            self: *Self,
            comptime delimiter: []const u8,
            malformed_code: DiagnosticCode,
        ) ReadError!bool {
            while (self.delimiter_index < delimiter.len) {
                if (self.utf8_len != 0) {
                    const consumed = self.source_byte_offset - self.token_start.byte_offset - 1;
                    const scalar_len = self.pendingUtf8ScalarLength() catch
                        return self.failVoid(.malformed_utf8, .invalid_xml);
                    const remaining_scalar = scalar_len - self.utf8_len;
                    if (remaining_scalar > self.options.limits.max_partial_token_bytes - consumed) {
                        return self.failVoid(.partial_token_limit, .limit_exceeded);
                    }
                    const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return false;
                    const start = self.utf8_start;
                    if (!isXml10Char(scalar.codepoint)) {
                        return self.failAt(.forbidden_character, .invalid_xml, start);
                    }
                    return self.failAt(malformed_code, .invalid_xml, start);
                }
                if (self.cursor == self.input.len) {
                    if (self.final_input) {
                        return self.failVoid(.incomplete_input, .invalid_xml);
                    }
                    return false;
                }
                const consumed = self.source_byte_offset - self.token_start.byte_offset - 1;
                if (consumed >= self.options.limits.max_partial_token_bytes) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                const byte = self.input[self.cursor];
                if (byte >= 0x80) {
                    const scalar_len = self.pendingUtf8ScalarLength() catch
                        return self.failVoid(.malformed_utf8, .invalid_xml);
                    if (scalar_len > self.options.limits.max_partial_token_bytes - consumed) {
                        return self.failVoid(.partial_token_limit, .limit_exceeded);
                    }
                    const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return false;
                    const start = self.utf8_start;
                    if (!isXml10Char(scalar.codepoint)) {
                        return self.failAt(.forbidden_character, .invalid_xml, start);
                    }
                    return self.failAt(malformed_code, .invalid_xml, start);
                }
                if (byte != delimiter[self.delimiter_index]) {
                    if (!isXml10Char(byte)) {
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                    return self.failVoid(malformed_code, .invalid_xml);
                }
                self.consumeByte(byte);
                self.delimiter_index += 1;
            }
            self.delimiter_index = 0;
            self.delimiter_len = 0;
            return true;
        }

        fn beginProcessingInstruction(
            self: *Self,
            context: MarkupContext,
            initial: bool,
        ) ReadError!void {
            self.clearAttributesRetainingCapacity();
            self.markup_context = context;
            self.processing_instruction_initial = initial;
            self.processing_instruction_target_len = 0;
            self.delimiter_len = 0;
            self.vertical_state = .processing_instruction_target;
        }

        fn appendProcessingInstructionTarget(
            self: *Self,
            bytes: []const u8,
        ) ReadError!void {
            const limit = self.options.limits.max_processing_instruction_target_bytes;
            if (self.processing_instruction_target_len > limit or
                bytes.len > limit - self.processing_instruction_target_len)
            {
                return self.failProcessingInstructionTargetLimit();
            }
            self.attribute_bytes.appendSlice(self.allocator, bytes) catch
                return self.failOutOfMemory();
            self.processing_instruction_target_len += bytes.len;
        }

        fn failProcessingInstructionTargetLimit(self: *Self) ReadError {
            const offset = 2 +| self.options.limits.max_processing_instruction_target_bytes;
            return self.failAt(
                .processing_instruction_target_limit,
                .limit_exceeded,
                locationWithByteDelta(config, self.token_start, offset),
            );
        }

        fn processingInstructionTarget(self: *const Self) []const u8 {
            return self.attribute_bytes.items[0..self.processing_instruction_target_len];
        }

        fn readProcessingInstructionTarget(self: *Self) ReadError!bool {
            const run_start = self.cursor;
            var run_end = run_start;
            while (run_end < self.input.len and isAsciiNameChar(self.input[run_end])) {
                run_end += 1;
            }
            if (run_end != run_start) {
                if (self.processing_instruction_target_len == 0 and
                    !isAsciiNameStart(self.input[run_start]))
                {
                    return self.failVoid(.malformed_processing_instruction, .invalid_xml);
                }
                const run = self.input[run_start..run_end];
                const target_limit = self.options.limits.max_processing_instruction_target_bytes;
                var remaining = if (self.processing_instruction_target_len < target_limit)
                    target_limit - self.processing_instruction_target_len
                else
                    0;
                if (self.processing_instruction_initial and
                    self.processing_instruction_target_len < 3)
                {
                    const target = self.processingInstructionTarget();
                    if (std.mem.eql(u8, target, "xml"[0..target.len])) {
                        var probe_len: usize = 0;
                        const probe_end = @min(run.len, 3 - target.len);
                        while (probe_len < probe_end and
                            run[probe_len] == "xml"[target.len + probe_len])
                        {
                            probe_len += 1;
                        }
                        remaining = @max(remaining, probe_len);
                    }
                }
                const accepted_len = @min(run.len, remaining);
                if (accepted_len > 0) {
                    self.attribute_bytes.appendSlice(
                        self.allocator,
                        run[0..accepted_len],
                    ) catch return self.failOutOfMemory();
                    self.processing_instruction_target_len += accepted_len;
                    self.consumeRun(run[0..accepted_len]);
                }
                if (accepted_len != run.len) {
                    return self.failProcessingInstructionTargetLimit();
                }
            }

            if (self.utf8_len != 0 and self.cursor == self.input.len) {
                _ = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                unreachable;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    if (self.processing_instruction_initial and
                        std.mem.eql(u8, self.processingInstructionTarget(), "xml"))
                    {
                        return self.failAt(
                            .incomplete_declaration,
                            .invalid_xml,
                            self.currentLocation(),
                        );
                    }
                    if (self.processing_instruction_target_len >
                        self.options.limits.max_processing_instruction_target_bytes)
                    {
                        return self.failProcessingInstructionTargetLimit();
                    }
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }
            if (self.processing_instruction_target_len >
                self.options.limits.max_processing_instruction_target_bytes and
                (!self.processing_instruction_initial or
                    !std.mem.eql(u8, self.processingInstructionTarget(), "xml") or
                    (!isXmlWhitespace(self.input[self.cursor]) and
                        self.input[self.cursor] != '?')))
            {
                return self.failProcessingInstructionTargetLimit();
            }
            if (self.utf8_len != 0 or self.input[self.cursor] >= 0x80) {
                const scalar_len = self.pendingUtf8ScalarLength() catch
                    return self.failVoid(.malformed_utf8, .invalid_xml);
                const target_limit =
                    self.options.limits.max_processing_instruction_target_bytes;
                if (self.processing_instruction_target_len > target_limit or
                    scalar_len > target_limit - self.processing_instruction_target_len)
                {
                    return self.failVoid(
                        .processing_instruction_target_limit,
                        .limit_exceeded,
                    );
                }
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                const valid = if (self.processing_instruction_target_len == 0)
                    isXml10NameStart(scalar.codepoint)
                else
                    isXml10NameChar(scalar.codepoint);
                if (!valid) {
                    return self.failAt(
                        .malformed_processing_instruction,
                        .invalid_xml,
                        start,
                    );
                }
                try self.appendProcessingInstructionTarget(self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                return false;
            }

            if (self.processing_instruction_target_len == 0) {
                return self.failVoid(.malformed_processing_instruction, .invalid_xml);
            }
            const byte = self.input[self.cursor];
            if (!isXmlWhitespace(byte) and byte != '?') {
                if (!isXml10Char(byte)) return self.failVoid(.forbidden_character, .invalid_xml);
                return self.failVoid(.malformed_processing_instruction, .invalid_xml);
            }

            const target = self.processingInstructionTarget();
            if (comptime config.profile.hasNamespaces()) {
                if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
                    return self.failAt(
                        .malformed_ncname,
                        .invalid_xml,
                        locationWithByteDelta(config, self.token_start, 2 + colon),
                    );
                }
            }
            if (self.processing_instruction_initial and
                std.mem.eql(u8, target, "xml") and isXmlWhitespace(byte))
            {
                const declaration_bytes =
                    self.source_byte_offset - self.token_start.byte_offset;
                const partial_limit = self.options.limits.max_partial_token_bytes;
                if (declaration_bytes > partial_limit) {
                    return self.failAt(
                        .partial_token_limit,
                        .limit_exceeded,
                        locationWithByteDelta(config, self.token_start, partial_limit),
                    );
                }
                self.clearAttributesRetainingCapacity();
                self.declaration_data_start = self.currentLocation();
                self.vertical_state = .declaration;
                return false;
            }
            if (isAsciiCaseInsensitiveXml(target)) {
                const code: DiagnosticCode = if (std.mem.eql(u8, target, "xml"))
                    .misplaced_xml_declaration
                else
                    .reserved_processing_instruction_target;
                if (self.processing_instruction_initial and byte == '?') {
                    return self.failAt(.malformed_declaration, .invalid_xml, self.token_start);
                }
                return self.failAt(code, .invalid_xml, self.token_start);
            }

            if (self.processing_instruction_initial) {
                self.document_start_span = self.token_start;
                self.document_start_resume = .processing_instruction_after_target;
                self.processing_instruction_initial = false;
                self.vertical_state = .emit_document_start;
            } else {
                self.vertical_state = .processing_instruction_after_target;
            }
            return false;
        }

        fn readProcessingInstructionAfterTarget(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }
            if (self.input[self.cursor] == '?') {
                self.vertical_state = .processing_instruction;
                return false;
            }
            std.debug.assert(isXmlWhitespace(self.input[self.cursor]));
            self.vertical_state = .processing_instruction_before_data;
            return false;
        }

        fn readProcessingInstructionBeforeData(self: *Self) ReadError!bool {
            self.consumeWhitespaceRun();
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }
            self.vertical_state = .processing_instruction;
            return false;
        }

        fn prepareCommentFragment(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
            complete: bool,
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            self.text_fragment = bytes;
            self.text_start = start;
            self.fragment_complete = complete;
            self.vertical_state = .emit_comment;
        }

        fn prepareProcessingInstructionFragment(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
            complete: bool,
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            self.text_fragment = bytes;
            self.text_start = start;
            self.fragment_complete = complete;
            self.vertical_state = .emit_processing_instruction;
        }

        fn prepareCdataFragment(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            self.text_fragment = bytes;
            self.text_start = start;
            self.text_origin = .cdata;
            self.text_resume = .cdata;
            self.vertical_state = .emit_text;
        }

        fn readComment(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const scalar_start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
                }
                @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                try self.prepareCommentFragment(
                    self.text_inline[0..scalar.len],
                    scalar_start,
                    false,
                );
                return false;
            }
            if (self.delimiter_len == 1) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_comment, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] == '-') {
                    self.consumeByte('-');
                    self.delimiter_bytes[1] = '-';
                    self.delimiter_len = 2;
                } else {
                    self.delimiter_len = 0;
                    try self.prepareCommentFragment("-", self.delimiter_start, false);
                    return false;
                }
            }
            if (self.delimiter_len == 2) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_comment, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] != '>') {
                    return self.failVoid(.malformed_comment, .invalid_xml);
                }
                self.consumeByte('>');
                self.delimiter_len = 0;
                try self.prepareCommentFragment(&.{}, self.delimiter_start, true);
                return false;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.unclosed_comment, .invalid_xml);
                return true;
            }

            const run_start = self.cursor;
            const start = self.currentLocation();
            var run_end = run_start;
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            while (run_end < fragment_end) {
                const byte = self.input[run_end];
                if (byte == '-' or byte == '\r') break;
                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (!isXml10Char(byte)) {
                        if (run_end != run_start) break;
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => break,
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (!isXml10Char(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                        },
                    }
                }
                if (scalar_len > self.options.limits.max_fragment_bytes -| (run_end - run_start)) {
                    if (run_end == run_start) {
                        return self.failAt(.fragment_limit, .limit_exceeded, start);
                    }
                    break;
                }
                run_end += scalar_len;
            }
            if (run_end != run_start) {
                const fragment = self.input[run_start..run_end];
                self.consumeRun(fragment);
                try self.prepareCommentFragment(fragment, start, false);
                return false;
            }

            const byte = self.input[self.cursor];
            if (byte == '-') {
                self.delimiter_start = self.currentLocation();
                self.consumeByte('-');
                self.delimiter_bytes[0] = '-';
                self.delimiter_len = 1;
                return false;
            }
            if (byte == '\r') {
                self.text_start = self.currentLocation();
                self.consumeByte('\r');
                self.vertical_state = .comment_after_carriage_return;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const scalar_start = self.utf8_start;
            if (!isXml10Char(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
            }
            @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
            self.clearUtf8Scalar();
            try self.prepareCommentFragment(self.text_inline[0..scalar.len], scalar_start, false);
            return false;
        }

        fn readCommentCarriageReturn(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len and !self.final_input) return true;
            if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                self.consumeByte('\n');
            }
            try self.prepareCommentFragment("\n", self.text_start, false);
            return false;
        }

        fn readProcessingInstruction(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const scalar_start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
                }
                @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                try self.prepareProcessingInstructionFragment(
                    self.text_inline[0..scalar.len],
                    scalar_start,
                    false,
                );
                return false;
            }
            if (self.delimiter_len == 1) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) {
                        return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                    }
                    return true;
                }
                if (self.input[self.cursor] == '>') {
                    self.consumeByte('>');
                    self.delimiter_len = 0;
                    try self.prepareProcessingInstructionFragment(
                        &.{},
                        self.delimiter_start,
                        true,
                    );
                    return false;
                }
                self.delimiter_len = 0;
                try self.prepareProcessingInstructionFragment(
                    "?",
                    self.delimiter_start,
                    false,
                );
                return false;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }

            const run_start = self.cursor;
            const start = self.currentLocation();
            var run_end = run_start;
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            while (run_end < fragment_end) {
                const byte = self.input[run_end];
                if (byte == '?' or byte == '\r') break;
                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (!isXml10Char(byte)) {
                        if (run_end != run_start) break;
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => break,
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (!isXml10Char(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                        },
                    }
                }
                if (scalar_len > self.options.limits.max_fragment_bytes -| (run_end - run_start)) {
                    if (run_end == run_start) {
                        return self.failAt(.fragment_limit, .limit_exceeded, start);
                    }
                    break;
                }
                run_end += scalar_len;
            }
            if (run_end != run_start) {
                const fragment = self.input[run_start..run_end];
                self.consumeRun(fragment);
                try self.prepareProcessingInstructionFragment(fragment, start, false);
                return false;
            }

            const byte = self.input[self.cursor];
            if (byte == '?') {
                self.delimiter_start = self.currentLocation();
                self.consumeByte('?');
                self.delimiter_bytes[0] = '?';
                self.delimiter_len = 1;
                return false;
            }
            if (byte == '\r') {
                self.text_start = self.currentLocation();
                self.consumeByte('\r');
                self.vertical_state = .processing_instruction_after_carriage_return;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const scalar_start = self.utf8_start;
            if (!isXml10Char(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
            }
            @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
            self.clearUtf8Scalar();
            try self.prepareProcessingInstructionFragment(
                self.text_inline[0..scalar.len],
                scalar_start,
                false,
            );
            return false;
        }

        fn readProcessingInstructionCarriageReturn(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len and !self.final_input) return true;
            if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                self.consumeByte('\n');
            }
            try self.prepareProcessingInstructionFragment("\n", self.text_start, false);
            return false;
        }

        fn readCdata(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const scalar_start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
                }
                @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                try self.prepareCdataFragment(self.text_inline[0..scalar.len], scalar_start);
                return false;
            }
            if (self.delimiter_len == 1) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_cdata, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] == ']') {
                    self.consumeByte(']');
                    self.delimiter_bytes[1] = ']';
                    self.delimiter_len = 2;
                } else {
                    self.delimiter_len = 0;
                    try self.prepareCdataFragment("]", self.delimiter_start);
                    return false;
                }
            }
            if (self.delimiter_len == 2) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_cdata, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] == '>') {
                    self.consumeByte('>');
                    self.delimiter_len = 0;
                    self.vertical_state = .content;
                    return false;
                }
                const start = self.delimiter_start;
                self.delimiter_start = locationWithByteDelta(config, start, 1);
                self.delimiter_len = 1;
                try self.prepareCdataFragment("]", start);
                return false;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.unclosed_cdata, .invalid_xml);
                return true;
            }

            const run_start = self.cursor;
            const start = self.currentLocation();
            var run_end = run_start;
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            while (run_end < fragment_end) {
                const byte = self.input[run_end];
                if (byte == ']' or byte == '\r') break;
                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (!isXml10Char(byte)) {
                        if (run_end != run_start) break;
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => break,
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (!isXml10Char(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                        },
                    }
                }
                if (scalar_len > self.options.limits.max_fragment_bytes -| (run_end - run_start)) {
                    if (run_end == run_start) {
                        return self.failAt(.fragment_limit, .limit_exceeded, start);
                    }
                    break;
                }
                run_end += scalar_len;
            }
            if (run_end != run_start) {
                const fragment = self.input[run_start..run_end];
                self.consumeRun(fragment);
                try self.prepareCdataFragment(fragment, start);
                return false;
            }

            const byte = self.input[self.cursor];
            if (byte == ']') {
                self.delimiter_start = self.currentLocation();
                self.consumeByte(']');
                self.delimiter_bytes[0] = ']';
                self.delimiter_len = 1;
                return false;
            }
            if (byte == '\r') {
                self.text_start = self.currentLocation();
                self.consumeByte('\r');
                self.vertical_state = .cdata_after_carriage_return;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const scalar_start = self.utf8_start;
            if (!isXml10Char(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
            }
            @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
            self.clearUtf8Scalar();
            try self.prepareCdataFragment(self.text_inline[0..scalar.len], scalar_start);
            return false;
        }

        fn readCdataCarriageReturn(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len and !self.final_input) return true;
            if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                self.consumeByte('\n');
            }
            try self.prepareCdataFragment("\n", self.text_start);
            return false;
        }

        fn consumeDeclarationByte(self: *Self, byte: u8) ReadError!void {
            const consumed = self.source_byte_offset - self.token_start.byte_offset;
            if (consumed >= self.options.limits.max_partial_token_bytes) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            self.consumeByte(byte);
        }

        fn appendDeclarationByte(self: *Self, byte: u8) ReadError!void {
            try self.consumeDeclarationByte(byte);
            self.attribute_bytes.append(self.allocator, byte) catch
                return self.failOutOfMemory();
        }

        fn readDeclaration(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.incomplete_declaration, .invalid_xml);
                return true;
            }
            const byte = self.input[self.cursor];
            if (byte == '?') {
                try self.consumeDeclarationByte('?');
                self.vertical_state = .declaration_question;
                return false;
            }
            if (self.utf8_len != 0 or byte >= 0x80) {
                const consumed = self.source_byte_offset - self.token_start.byte_offset;
                const limit = self.options.limits.max_partial_token_bytes;
                if (consumed >= limit) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                const scalar_len = self.pendingUtf8ScalarLength() catch
                    return self.failVoid(.malformed_utf8, .invalid_xml);
                const remaining_scalar = scalar_len - self.utf8_len;
                if (remaining_scalar > limit - consumed) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                return self.failAt(.malformed_declaration, .invalid_xml, start);
            }
            if (!isXml10Char(byte)) return self.failVoid(.forbidden_character, .invalid_xml);
            try self.appendDeclarationByte(byte);
            return false;
        }

        fn readDeclarationQuestion(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.incomplete_declaration, .invalid_xml);
                return true;
            }
            if (self.input[self.cursor] != '>') {
                self.attribute_bytes.append(self.allocator, '?') catch
                    return self.failOutOfMemory();
                self.vertical_state = .declaration;
                return false;
            }
            try self.consumeDeclarationByte('>');
            try self.finishDeclaration();
            self.document_start_span = self.token_start;
            self.document_start_resume = .release_document_start;
            self.vertical_state = .emit_document_start;
            return false;
        }

        fn finishDeclaration(self: *Self) ReadError!void {
            switch (parseXmlDeclaration(self.attribute_bytes.items)) {
                .parsed => |parsed| {
                    self.declared_version_offset = parsed.version_offset;
                    self.declared_version_len = parsed.version_len;
                    self.declared_encoding_offset = parsed.encoding_offset;
                    self.declared_encoding_len = parsed.encoding_len;
                    self.standalone = parsed.standalone;
                    self.standalone_declared = parsed.standalone_declared;
                },
                .malformed => |index| return self.failAt(
                    .malformed_declaration,
                    .invalid_xml,
                    self.declarationLocation(index),
                ),
                .unsupported_version => |index| return self.failAt(
                    .unsupported_version,
                    .invalid_xml,
                    self.declarationLocation(index),
                ),
                .unsupported_encoding => |index| return self.failAt(
                    .unsupported_encoding,
                    .unsupported_feature,
                    self.declarationLocation(index),
                ),
            }
        }

        fn declarationLocation(self: *const Self, index: usize) Location(config) {
            var location = self.declaration_data_start;
            var pending_carriage_return = false;
            for (self.attribute_bytes.items[0..@min(index, self.attribute_bytes.items.len)]) |byte| {
                location.byte_offset += 1;
                if (config.diagnostic_location == .line_column) {
                    if (pending_carriage_return and byte == '\n') {
                        location.byte_column = 1;
                        pending_carriage_return = false;
                        continue;
                    }
                    pending_carriage_return = false;
                    if (byte == '\r') {
                        location.line += 1;
                        location.byte_column = 1;
                        pending_carriage_return = true;
                    } else if (byte == '\n') {
                        location.line += 1;
                        location.byte_column = 1;
                    } else {
                        location.byte_column += 1;
                    }
                }
            }
            return location;
        }

        fn readUtf8Scalar(self: *Self, source: ScalarSource) ReadError!?DecodedScalar {
            if (self.utf8_len == 0) {
                std.debug.assert(self.cursor < self.input.len);
                self.utf8_start = self.currentLocation();
                const lead = self.input[self.cursor];
                self.utf8_expected_len = utf8ExpectedLength(lead) orelse
                    return self.fail(.malformed_utf8, .invalid_xml);
            }

            while (self.utf8_len < self.utf8_expected_len) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) {
                        return self.failAt(
                            .malformed_utf8,
                            .invalid_xml,
                            self.utf8_start,
                        );
                    }
                    return null;
                }
                const byte = self.input[self.cursor];
                const index: usize = self.utf8_len;
                if (index > 0 and (byte < 0x80 or byte > 0xbf or
                    (index == 1 and !validUtf8SecondByte(self.utf8_bytes[0], byte))))
                {
                    return self.fail(.malformed_utf8, .invalid_xml);
                }
                switch (source) {
                    .ordinary => self.consumeByte(byte),
                    .start_tag => {
                        try self.requireStartTagByte();
                        self.consumeStartTagByte(byte);
                    },
                    .reference => try self.consumeReferenceByte(byte),
                }
                self.utf8_bytes[index] = byte;
                self.utf8_len += 1;
            }

            const bytes = self.utf8_bytes[0..self.utf8_expected_len];
            const codepoint = std.unicode.utf8Decode(bytes) catch unreachable;
            return .{ .codepoint = codepoint, .len = self.utf8_expected_len };
        }

        fn clearUtf8Scalar(self: *Self) void {
            self.utf8_len = 0;
            self.utf8_expected_len = 0;
        }

        fn rejectNonAsciiMarkup(
            self: *Self,
            code: DiagnosticCode,
        ) ReadError!bool {
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const start = self.utf8_start;
            if (!isXml10Char(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            return self.failAt(code, .invalid_xml, start);
        }

        fn rejectStartTagNonAsciiMarkup(
            self: *Self,
            code: DiagnosticCode,
        ) ReadError!bool {
            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse return true;
            const start = self.utf8_start;
            if (!isXml10Char(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            return self.failAt(code, .invalid_xml, start);
        }

        fn prepareContentRun(self: *Self) ReadError!bool {
            std.debug.assert(self.utf8_len == 0);
            const run_start = self.cursor;
            const start = self.currentLocation();
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            const candidate = self.input[run_start..fragment_end];
            if (contentHasOrdinaryPrefix(candidate) and
                self.prepareBulkContentRun(candidate, start))
            {
                return true;
            }

            var run_end = run_start;
            var close_brackets = self.text_close_brackets;
            while (run_end < fragment_end) {
                const byte = self.input[run_end];

                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (byte == '<' or byte == '&' or byte == '\r') break;
                    if (!isXml10Char(byte)) {
                        if (run_end != run_start) break;
                        return self.fail(.forbidden_character, .invalid_xml);
                    }
                    if (byte == '>' and close_brackets == 2) {
                        if (run_end != run_start) break;
                        return self.fail(.cdata_close_in_text, .invalid_xml);
                    }
                    close_brackets = if (byte == ']') @min(close_brackets + 1, 2) else 0;
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => {
                            if (run_end != run_start) break;
                            return false;
                        },
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (!isXml10Char(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                            close_brackets = 0;
                        },
                    }
                }

                const current_len = run_end - run_start;
                if (scalar_len > self.options.limits.max_fragment_bytes -| current_len) {
                    if (run_end == run_start) {
                        return self.fail(.fragment_limit, .limit_exceeded);
                    }
                    break;
                }
                run_end += scalar_len;
            }

            if (run_end == run_start) return false;
            const fragment = self.input[run_start..run_end];
            self.consumeRun(fragment);
            self.text_close_brackets = close_brackets;
            self.text_fragment = fragment;
            self.text_start = start;
            self.text_origin = .character_data;
            self.text_resume = .content;
            self.vertical_state = .emit_text;
            return true;
        }

        fn contentHasOrdinaryPrefix(run: []const u8) bool {
            if (run.len < 64) return false;
            for (run[0..8]) |byte| {
                if (byte == '<' or byte == '&' or byte == '\r' or byte == ']') {
                    return false;
                }
            }
            return true;
        }

        noinline fn prepareBulkContentRun(
            self: *Self,
            candidate: []const u8,
            start: Location(config),
        ) bool {
            const unicode_dense = contentStartsUnicodeDense(candidate);
            const scan = if (unicode_dense) scanContentStructure(candidate) else null;
            var fast_len = if (scan) |result| result.delimiter_index else candidate.len;
            if (!unicode_dense) {
                inline for ("<&\r") |delimiter| {
                    if (std.mem.indexOfScalar(u8, candidate[0..fast_len], delimiter)) |index| {
                        fast_len = index;
                    }
                }
            }
            if (contentCdataCloseIndex(
                self.text_close_brackets,
                candidate[0..fast_len],
            )) |index| {
                fast_len = index;
            }
            const fast_run = candidate[0..fast_len];
            if (fast_run.len == 0 or
                !contentRunCanUseBulkPath(
                    fast_run,
                    if (scan) |result| result.has_non_ascii else hasNonAscii(fast_run),
                )) return false;
            self.consumeRun(fast_run);
            self.text_close_brackets = contentTrailingCloseBrackets(
                self.text_close_brackets,
                fast_run,
            );
            self.text_fragment = fast_run;
            self.text_start = start;
            self.text_origin = .character_data;
            self.text_resume = .content;
            self.vertical_state = .emit_text;
            return true;
        }

        fn contentRunCanUseBulkPath(run: []const u8, has_non_ascii: bool) bool {
            if (has_non_ascii) {
                if (!utf8AndXmlControlsValid(run)) return false;
            } else if (hasForbiddenAsciiControl(run)) return false;
            return true;
        }

        fn contentCdataCloseIndex(close_brackets: u2, run: []const u8) ?usize {
            var earliest: ?usize = null;
            if (close_brackets == 2 and run.len > 0 and run[0] == '>') {
                earliest = 0;
            } else if (close_brackets == 1 and run.len > 1 and
                run[0] == ']' and run[1] == '>')
            {
                earliest = 1;
            }
            if (std.mem.indexOf(u8, run, "]]>")) |start| {
                const index = start + 2;
                if (earliest == null or index < earliest.?) earliest = index;
            }
            return earliest;
        }

        fn contentTrailingCloseBrackets(previous: u2, run: []const u8) u2 {
            std.debug.assert(run.len > 0);
            if (run[run.len - 1] != ']') return 0;
            if (run.len >= 2) return if (run[run.len - 2] == ']') 2 else 1;
            return @min(previous + 1, 2);
        }

        fn prepareInlineText(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            std.debug.assert(bytes.len <= self.text_inline.len);
            @memcpy(self.text_inline[0..bytes.len], bytes);
            self.text_fragment = self.text_inline[0..bytes.len];
            self.text_start = start;
            self.text_origin = .character_data;
            self.text_resume = .content;
            self.vertical_state = .emit_text;
        }

        fn beginReference(self: *Self, context: ReferenceContext) ReadError!void {
            self.reference_context = context;
            self.reference_start = self.currentLocation();
            self.reference_value = 0;
            self.reference_has_digits = false;
            self.reference_token_bytes = 0;
            self.reference_name = @splat(0);
            self.reference_name_len = 0;
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.reference_colon = null;
            }
            try self.consumeReferenceByte('&');
            self.vertical_state = .reference_start;
        }

        fn prepareCompleteContentReference(self: *Self) ReadError!bool {
            const input = self.input[self.cursor..];
            const start = self.currentLocation();
            const predefined = .{
                .{ "&amp;", "&" },
                .{ "&lt;", "<" },
                .{ "&gt;", ">" },
                .{ "&apos;", "'" },
                .{ "&quot;", "\"" },
            };
            inline for (predefined) |entry| {
                const token = entry[0];
                const output = entry[1];
                if (std.mem.startsWith(u8, input, token) and
                    token.len <= self.options.limits.max_partial_token_bytes and
                    output.len <= self.options.limits.max_fragment_bytes)
                {
                    self.consumeRun(input[0..token.len]);
                    try self.prepareInlineText(output, start);
                    return true;
                }
            }

            if (!std.mem.startsWith(u8, input, "&#")) return false;
            var index: usize = 2;
            var kind: ReferenceKind = .decimal;
            if (index < input.len and input[index] == 'x') {
                kind = .hexadecimal;
                index += 1;
            }
            const digits_start = index;
            var value: u32 = 0;
            const base: u32 = if (kind == .hexadecimal) 16 else 10;
            while (index < input.len and input[index] != ';') : (index += 1) {
                const digit = referenceDigit(input[index], kind) orelse return false;
                if (value > (0x10ffff - digit) / base) return false;
                value = value * base + digit;
            }
            if (index == digits_start or index == input.len or
                index + 1 > self.options.limits.max_partial_token_bytes or
                !isXml10Char(@intCast(value)))
            {
                return false;
            }
            var output: [4]u8 = undefined;
            const output_len = std.unicode.utf8Encode(@intCast(value), &output) catch
                unreachable;
            if (output_len > self.options.limits.max_fragment_bytes) return false;
            self.consumeRun(input[0 .. index + 1]);
            try self.prepareInlineText(output[0..output_len], start);
            return true;
        }

        fn consumeReferenceByte(self: *Self, byte: u8) ReadError!void {
            if (self.reference_token_bytes == self.options.limits.max_partial_token_bytes) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            if (self.reference_context == .attribute) {
                try self.requireStartTagByte();
                self.consumeStartTagByte(byte);
            } else {
                self.consumeByte(byte);
            }
            self.reference_token_bytes += 1;
        }

        fn readReferenceStart(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
                const start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                if (!isXml10NameStart(scalar.codepoint)) {
                    return self.failAt(.malformed_reference, .invalid_xml, start);
                }
                self.reference_name_len += scalar.len;
                self.clearUtf8Scalar();
                self.vertical_state = .reference_entity;
                return false;
            }
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == '#') {
                try self.consumeReferenceByte(byte);
                self.vertical_state = .reference_numeric_prefix;
                return false;
            }
            if (byte < 0x80) {
                if (!isXml10Char(byte)) {
                    return self.failVoid(.forbidden_character, .invalid_xml);
                }
                if (!isXml10NameStart(byte)) {
                    return self.failVoid(.malformed_reference, .invalid_xml);
                }
                try self.consumeReferenceNameAscii(byte);
                self.vertical_state = .reference_entity;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
            const start = self.utf8_start;
            if (!isXml10Char(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            if (!isXml10NameStart(scalar.codepoint)) {
                return self.failAt(.malformed_reference, .invalid_xml, start);
            }
            self.reference_name_len += scalar.len;
            self.clearUtf8Scalar();
            self.vertical_state = .reference_entity;
            return false;
        }

        fn readReferenceNumericPrefix(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == 'x') {
                self.reference_kind = .hexadecimal;
                try self.consumeReferenceByte(byte);
                self.vertical_state = .reference_numeric;
                return false;
            }
            self.reference_kind = .decimal;
            self.vertical_state = .reference_numeric;
            return false;
        }

        fn readReferenceNumeric(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                _ = (try self.readUtf8Scalar(.reference)) orelse return true;
                return self.failAt(
                    .malformed_reference,
                    .invalid_xml,
                    self.utf8_start,
                );
            }
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == ';') {
                if (!self.reference_has_digits) {
                    return self.failVoid(.malformed_reference, .invalid_xml);
                }
                try self.consumeReferenceByte(byte);
                try self.finishNumericReference();
                return false;
            }
            if (byte >= 0x80) {
                _ = (try self.readUtf8Scalar(.reference)) orelse return true;
                return self.failAt(
                    .malformed_reference,
                    .invalid_xml,
                    self.utf8_start,
                );
            }
            const digit = referenceDigit(byte, self.reference_kind) orelse {
                if (byte < 0x20 and !isXml10Char(byte)) {
                    return self.failVoid(.forbidden_character, .invalid_xml);
                }
                return self.failVoid(.malformed_reference, .invalid_xml);
            };
            try self.consumeReferenceByte(byte);
            self.reference_has_digits = true;
            const base: u32 = if (self.reference_kind == .hexadecimal) 16 else 10;
            if (self.reference_value <= 0x10ffff and
                self.reference_value <= (0x10ffff - digit) / base)
            {
                self.reference_value = self.reference_value * base + digit;
            } else {
                self.reference_value = 0x110000;
            }
            return false;
        }

        fn readReferenceEntity(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
                const start = self.utf8_start;
                if (!isXml10Char(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                if (!isXml10NameChar(scalar.codepoint)) {
                    return self.failAt(.malformed_reference, .invalid_xml, start);
                }
                self.reference_name_len += scalar.len;
                self.clearUtf8Scalar();
                return false;
            }
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == ';') {
                try self.consumeReferenceByte(byte);
                try self.finishEntityReference();
                return false;
            }
            if (byte < 0x80) {
                if (!isXml10Char(byte)) {
                    return self.failVoid(.forbidden_character, .invalid_xml);
                }
                if (!isXml10NameChar(byte)) {
                    return self.failVoid(.malformed_reference, .invalid_xml);
                }
                try self.consumeReferenceNameAscii(byte);
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
            const start = self.utf8_start;
            if (!isXml10Char(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            if (!isXml10NameChar(scalar.codepoint)) {
                return self.failAt(.malformed_reference, .invalid_xml, start);
            }
            self.reference_name_len += scalar.len;
            self.clearUtf8Scalar();
            return false;
        }

        fn consumeReferenceNameAscii(self: *Self, byte: u8) ReadError!void {
            if (comptime config.profile.hasNamespaces()) {
                if (byte == ':' and self.namespace_state.reference_colon == null) {
                    self.namespace_state.reference_colon = self.currentLocation();
                }
            }
            try self.consumeReferenceByte(byte);
            if (self.reference_name_len < self.reference_name.len) {
                self.reference_name[self.reference_name_len] = byte;
            }
            self.reference_name_len += 1;
        }

        fn referenceNeedsInput(self: *Self) ReadError!bool {
            if (self.final_input) {
                return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
            }
            return true;
        }

        fn finishNumericReference(self: *Self) ReadError!void {
            if (self.reference_value > 0x10ffff or
                !isXml10Char(@intCast(self.reference_value)))
            {
                return self.failAt(
                    .invalid_character_reference,
                    .invalid_xml,
                    self.reference_start,
                );
            }
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(self.reference_value), &bytes) catch
                unreachable;
            try self.finishReferenceOutput(bytes[0..len]);
        }

        fn finishEntityReference(self: *Self) ReadError!void {
            if (comptime config.profile.hasNamespaces()) {
                if (self.namespace_state.reference_colon) |location| {
                    return self.failAt(.malformed_ncname, .invalid_xml, location);
                }
            }
            const bytes = predefinedEntity(
                self.reference_name[0..@min(self.reference_name_len, self.reference_name.len)],
                self.reference_name_len,
            ) orelse return self.failAt(
                .undeclared_entity,
                .invalid_xml,
                self.reference_start,
            );
            try self.finishReferenceOutput(bytes);
        }

        fn finishReferenceOutput(self: *Self, bytes: []const u8) ReadError!void {
            if (self.reference_context == .attribute) {
                try self.appendAttributeOutput(bytes);
                self.vertical_state = .attribute_value;
                return;
            }
            self.text_close_brackets = 0;
            try self.prepareInlineText(
                bytes,
                self.reference_start,
            );
        }

        fn appendAttributeOutput(self: *Self, bytes: []const u8) ReadError!void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            const value_len = self.attribute_bytes.items.len - value_offset;
            const value_remaining = self.options.limits.max_attribute_value_bytes - value_len;
            if (bytes.len > value_remaining) {
                return self.failVoid(.attribute_value_limit, .limit_exceeded);
            }
            const aggregate_remaining = self.options.limits.max_attribute_bytes_per_element -
                self.attribute_bytes.items.len;
            if (bytes.len > aggregate_remaining) {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            self.attribute_bytes.appendSlice(self.allocator, bytes) catch
                return self.failOutOfMemory();
        }

        fn beginStartElement(self: *Self) ReadError!void {
            if (self.open_elements.items.len == self.options.limits.max_depth) {
                return self.failVoid(.depth_limit, .limit_exceeded);
            }
            std.debug.assert(self.attribute_records.items.len == 0);
            std.debug.assert(self.attribute_bytes.items.len == 0);
            std.debug.assert(self.event_attributes.items.len == 0);
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
            const start_tag_remaining = self.startTagRemaining();
            const qname_remaining = self.qnameRemaining(self.token_name_len);
            const accepted_len = @min(
                run.len,
                @min(
                    partial_remaining,
                    @min(open_remaining, @min(qname_remaining, start_tag_remaining)),
                ),
            );
            if (accepted_len > 0) {
                self.open_names.appendSlice(
                    self.allocator,
                    run[0..accepted_len],
                ) catch return self.failOutOfMemory();
                self.consumeStartTagRun(run[0..accepted_len]);
                self.token_name_len += accepted_len;
            }
            if (accepted_len != run.len) {
                if (self.token_name_len == self.options.limits.max_partial_token_bytes) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                if (self.open_names.items.len == self.options.limits.max_open_name_bytes) {
                    return self.failVoid(.open_name_limit, .limit_exceeded);
                }
                if (comptime config.profile.hasNamespaces()) {
                    if (self.token_name_len == self.options.namespace_limits.max_qname_bytes) {
                        return self.failVoid(.qname_limit, .limit_exceeded);
                    }
                }
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn ensureStartNameScalarCapacity(self: *Self) ReadError!void {
            const scalar_len = self.pendingUtf8ScalarLength() catch
                return self.failVoid(.malformed_utf8, .invalid_xml);
            if (scalar_len > self.options.limits.max_partial_token_bytes - self.token_name_len) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            if (scalar_len > self.options.limits.max_open_name_bytes - self.open_names.items.len) {
                return self.failVoid(.open_name_limit, .limit_exceeded);
            }
            if (scalar_len > self.qnameRemaining(self.token_name_len)) {
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
            if (scalar_len > self.startTagRemaining()) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn appendDecodedStartName(self: *Self, len: usize) ReadError!void {
            self.open_names.appendSlice(self.allocator, self.utf8_bytes[0..len]) catch
                return self.failOutOfMemory();
            self.token_name_len += len;
        }

        fn finishStartElement(self: *Self, empty_element: bool) ReadError!void {
            if (comptime config.profile.hasNamespaces()) {
                const binding_mark = self.namespace_state.bindings.items.len;
                const byte_mark = self.namespace_state.bytes.items.len;
                const namespace_reference = try self.prepareNamespaceStartElement();
                self.open_elements.append(self.allocator, .{
                    .name_offset = self.open_names.items.len - self.token_name_len,
                    .name_len = self.token_name_len,
                    .start = self.token_start,
                    .namespace_binding_mark = binding_mark,
                    .namespace_byte_mark = byte_mark,
                    .namespace_reference = namespace_reference,
                }) catch return self.failOutOfMemory();
            } else {
                try self.prepareEventAttributes();
                self.open_elements.append(self.allocator, .{
                    .name_offset = self.open_names.items.len - self.token_name_len,
                    .name_len = self.token_name_len,
                    .start = self.token_start,
                }) catch return self.failOutOfMemory();
            }
            self.vertical_state = if (empty_element)
                .emit_empty_start_element
            else
                .emit_start_element;
        }

        fn beginAttribute(self: *Self) ReadError!void {
            if (self.attribute_records.items.len ==
                self.options.limits.max_attributes_per_element)
            {
                return self.failVoid(.attribute_count_limit, .limit_exceeded);
            }
            if (self.attribute_bytes.items.len ==
                self.options.limits.max_attribute_bytes_per_element)
            {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            try self.requireStartTagByte();
            self.attribute_records.append(self.allocator, .{
                .name_offset = self.attribute_bytes.items.len,
                .name_len = 0,
                .value_len = 0,
                .start = self.currentLocation(),
            }) catch return self.failOutOfMemory();
            self.vertical_state = .attribute_name;
        }

        fn appendAttributeNameRun(self: *Self, run: []const u8) ReadError!void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const name_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_name_bytes,
                record.name_len,
            ) catch unreachable;
            const aggregate_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_bytes_per_element,
                self.attribute_bytes.items.len,
            ) catch unreachable;
            const qname_remaining = self.qnameRemaining(record.name_len);
            const accepted_len = @min(
                run.len,
                @min(
                    name_remaining,
                    @min(aggregate_remaining, @min(qname_remaining, self.startTagRemaining())),
                ),
            );
            if (accepted_len > 0) {
                self.attribute_bytes.appendSlice(
                    self.allocator,
                    run[0..accepted_len],
                ) catch return self.failOutOfMemory();
                self.consumeStartTagRun(run[0..accepted_len]);
                record.name_len += accepted_len;
            }
            if (accepted_len != run.len) {
                if (record.name_len == self.options.limits.max_attribute_name_bytes) {
                    return self.failVoid(.attribute_name_limit, .limit_exceeded);
                }
                if (self.attribute_bytes.items.len ==
                    self.options.limits.max_attribute_bytes_per_element)
                {
                    return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
                }
                if (comptime config.profile.hasNamespaces()) {
                    if (record.name_len == self.options.namespace_limits.max_qname_bytes) {
                        return self.failVoid(.qname_limit, .limit_exceeded);
                    }
                }
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn ensureAttributeNameScalarCapacity(self: *Self) ReadError!void {
            const scalar_len = self.pendingUtf8ScalarLength() catch
                return self.failVoid(.malformed_utf8, .invalid_xml);
            const record = self.attribute_records.items[self.attribute_records.items.len - 1];
            if (scalar_len > self.options.limits.max_attribute_name_bytes - record.name_len) {
                return self.failVoid(.attribute_name_limit, .limit_exceeded);
            }
            if (scalar_len > self.options.limits.max_attribute_bytes_per_element -
                self.attribute_bytes.items.len)
            {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            if (scalar_len > self.qnameRemaining(record.name_len)) {
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
            if (scalar_len > self.startTagRemaining()) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn appendDecodedAttributeName(self: *Self, len: usize) ReadError!void {
            self.attribute_bytes.appendSlice(
                self.allocator,
                self.utf8_bytes[0..len],
            ) catch return self.failOutOfMemory();
            self.attribute_records.items[self.attribute_records.items.len - 1].name_len += len;
        }

        fn qnameRemaining(self: *const Self, current_len: usize) usize {
            if (comptime !config.profile.hasNamespaces()) return std.math.maxInt(usize);
            return self.options.namespace_limits.max_qname_bytes - current_len;
        }

        fn appendAttributeValueRun(self: *Self, run: []const u8) ReadError!void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            const value_len = self.attribute_bytes.items.len - value_offset;
            const value_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_value_bytes,
                value_len,
            ) catch unreachable;
            const aggregate_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_bytes_per_element,
                self.attribute_bytes.items.len,
            ) catch unreachable;
            const accepted_len = @min(
                run.len,
                @min(value_remaining, @min(aggregate_remaining, self.startTagRemaining())),
            );
            if (accepted_len > 0) {
                self.attribute_bytes.appendSlice(
                    self.allocator,
                    run[0..accepted_len],
                ) catch return self.failOutOfMemory();
                self.consumeStartTagRun(run[0..accepted_len]);
            }
            if (accepted_len != run.len) {
                if (value_len + accepted_len ==
                    self.options.limits.max_attribute_value_bytes)
                {
                    return self.failVoid(.attribute_value_limit, .limit_exceeded);
                }
                if (self.attribute_bytes.items.len ==
                    self.options.limits.max_attribute_bytes_per_element)
                {
                    return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
                }
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn ensureAttributeValueScalarCapacity(self: *Self) ReadError!void {
            const scalar_len = self.pendingUtf8ScalarLength() catch
                return self.failVoid(.malformed_utf8, .invalid_xml);
            const record = self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            const value_len = self.attribute_bytes.items.len - value_offset;
            if (scalar_len > self.options.limits.max_attribute_value_bytes - value_len) {
                return self.failVoid(.attribute_value_limit, .limit_exceeded);
            }
            if (scalar_len > self.options.limits.max_attribute_bytes_per_element -
                self.attribute_bytes.items.len)
            {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            if (scalar_len > self.startTagRemaining()) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn finishAttribute(self: *Self) void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            record.value_len = self.attribute_bytes.items.len - value_offset;
        }

        fn prepareNamespaceStartElement(self: *Self) ReadError!NamespaceReference {
            try self.rejectDuplicateAttributes();
            self.namespace_state.event_declarations.clearRetainingCapacity();
            self.namespace_state.expanded_indices.clearRetainingCapacity();
            self.namespace_state.event_attribute_locations.clearRetainingCapacity();
            self.namespace_state.comparison_work = 0;

            const element_raw = self.open_names.items[self.open_names.items.len - self.token_name_len ..];
            const element_name_start = locationWithByteDelta(config, self.token_start, 1);
            const element_parts = try self.requireQName(element_raw, element_name_start);
            if (element_parts.prefix) |prefix| {
                if (std.mem.eql(u8, prefix, "xmlns")) {
                    return self.failAt(
                        .reserved_namespace_name,
                        .invalid_xml,
                        element_name_start,
                    );
                }
            }

            var declaration_count: usize = 0;
            for (self.attribute_records.items) |*record| {
                const raw = self.attributeRawName(record.*);
                const parts = try self.requireQName(raw, record.start);
                if (namespaceDeclarationPrefix(raw, parts)) |declared_prefix| {
                    record.namespace_shape = std.math.maxInt(usize);
                    declaration_count += 1;
                    if (declaration_count >
                        self.options.namespace_limits.max_declarations_per_element)
                    {
                        return self.failAt(
                            .namespace_declaration_limit,
                            .limit_exceeded,
                            record.start,
                        );
                    }
                    try self.addNamespaceDeclaration(record.*, declared_prefix);
                } else if (parts.prefix) |prefix| {
                    record.namespace_shape = prefix.len + 1;
                }
            }

            const element_reference = try self.resolveNamespace(
                element_parts.prefix orelse "",
                element_name_start,
            );

            const ordinary_count = self.attribute_records.items.len - declaration_count;
            self.event_attributes.clearRetainingCapacity();
            self.event_attributes.ensureTotalCapacity(
                self.allocator,
                ordinary_count,
            ) catch return self.failOutOfMemory();
            self.namespace_state.expanded_indices.ensureTotalCapacity(
                self.allocator,
                ordinary_count,
            ) catch return self.failOutOfMemory();
            self.namespace_state.event_attribute_locations.ensureTotalCapacity(
                self.allocator,
                ordinary_count,
            ) catch return self.failOutOfMemory();

            for (self.attribute_records.items) |record| {
                const raw = self.attributeRawName(record);
                if (record.namespace_shape == std.math.maxInt(usize)) continue;
                const parts: QNameParts = if (record.namespace_shape == 0)
                    .{ .prefix = null, .local = raw }
                else parts: {
                    const colon = record.namespace_shape - 1;
                    break :parts .{
                        .prefix = raw[0..colon],
                        .local = raw[colon + 1 ..],
                    };
                };
                if (parts.prefix) |prefix| {
                    if (std.mem.eql(u8, prefix, "xmlns")) {
                        return self.failAt(
                            .reserved_namespace_name,
                            .invalid_xml,
                            record.start,
                        );
                    }
                }
                const reference = if (parts.prefix) |prefix|
                    try self.resolveNamespace(prefix, record.start)
                else
                    NamespaceReference.none;
                const value_offset = record.name_offset + record.name_len;
                self.event_attributes.appendAssumeCapacity(.{
                    .name = self.expandedName(raw, parts, reference),
                    .value = self.attribute_bytes.items[value_offset..][0..record.value_len],
                });
                self.namespace_state.expanded_indices.appendAssumeCapacity(
                    self.event_attributes.items.len - 1,
                );
                self.namespace_state.event_attribute_locations.appendAssumeCapacity(record.start);
            }
            try self.rejectDuplicateExpandedAttributes();
            return element_reference;
        }

        fn requireQName(
            self: *Self,
            raw: []const u8,
            start: Location(config),
        ) ReadError!QNameParts {
            if (raw.len > self.options.namespace_limits.max_qname_bytes) {
                return self.failAt(
                    .qname_limit,
                    .limit_exceeded,
                    locationWithByteDelta(
                        config,
                        start,
                        self.options.namespace_limits.max_qname_bytes,
                    ),
                );
            }
            return qnameParts(raw) orelse self.failAt(
                .malformed_qname,
                .invalid_xml,
                locationWithByteDelta(config, start, qnameErrorIndex(raw)),
            );
        }

        fn addNamespaceDeclaration(
            self: *Self,
            record: AttributeRecord(config),
            declared_prefix: []const u8,
        ) ReadError!void {
            const raw = self.attributeRawName(record);
            const uri_offset = record.name_offset + record.name_len;
            const uri = self.attribute_bytes.items[uri_offset..][0..record.value_len];
            const is_default = std.mem.eql(u8, raw, "xmlns");

            if ((!is_default and uri.len == 0) or
                std.mem.eql(u8, declared_prefix, "xmlns") or
                std.mem.eql(u8, uri, xmlns_namespace_uri) or
                (std.mem.eql(u8, declared_prefix, "xml") !=
                    std.mem.eql(u8, uri, xml_namespace_uri)))
            {
                return self.failAt(
                    .illegal_namespace_declaration,
                    .invalid_xml,
                    record.start,
                );
            }
            if (std.mem.eql(u8, declared_prefix, "xml")) {
                self.namespace_state.event_declarations.append(self.allocator, .{
                    .prefix = declared_prefix,
                    .namespace_uri = uri,
                }) catch return self.failOutOfMemory();
                return;
            }
            if (self.namespace_state.bindings.items.len ==
                self.options.namespace_limits.max_active_bindings)
            {
                return self.failAt(.namespace_binding_limit, .limit_exceeded, record.start);
            }
            const added_bytes = std.math.add(usize, declared_prefix.len, uri.len) catch
                return self.failAt(.namespace_binding_bytes_limit, .limit_exceeded, record.start);
            if (added_bytes > self.options.namespace_limits.max_binding_bytes -
                self.namespace_state.bytes.items.len)
            {
                return self.failAt(
                    .namespace_binding_bytes_limit,
                    .limit_exceeded,
                    record.start,
                );
            }

            const prefix_offset = self.namespace_state.bytes.items.len;
            self.namespace_state.bytes.appendSlice(self.allocator, declared_prefix) catch
                return self.failOutOfMemory();
            const stored_uri_offset = self.namespace_state.bytes.items.len;
            self.namespace_state.bytes.appendSlice(self.allocator, uri) catch
                return self.failOutOfMemory();
            const active = try self.findActivePrefix(declared_prefix, record.start);
            const binding_index = self.namespace_state.bindings.items.len;
            self.namespace_state.bindings.append(self.allocator, .{
                .prefix_offset = prefix_offset,
                .prefix_len = declared_prefix.len,
                .uri_offset = stored_uri_offset,
                .uri_len = uri.len,
                .previous_binding = if (active.found)
                    self.namespace_state.active_prefixes.items[active.index]
                else
                    null,
                .active_index = active.index,
            }) catch return self.failOutOfMemory();
            if (active.found) {
                self.namespace_state.active_prefixes.items[active.index] = binding_index;
            } else {
                self.namespace_state.active_prefixes.insert(
                    self.allocator,
                    active.index,
                    binding_index,
                ) catch return self.failOutOfMemory();
            }
            self.namespace_state.event_declarations.append(self.allocator, .{
                .prefix = if (is_default) null else raw["xmlns:".len..],
                .namespace_uri = uri,
            }) catch return self.failOutOfMemory();
        }

        fn resolveNamespace(
            self: *Self,
            prefix: []const u8,
            location: Location(config),
        ) ReadError!NamespaceReference {
            if (std.mem.eql(u8, prefix, "xml")) return .predefined_xml;
            const active = try self.findActivePrefix(prefix, location);
            if (active.found) {
                const binding_index = self.namespace_state.active_prefixes.items[active.index];
                const binding = self.namespace_state.bindings.items[binding_index];
                return if (binding.uri_len == 0) .none else .{ .binding = binding_index };
            }
            if (prefix.len == 0) return .none;
            return self.failAt(.unbound_prefix, .invalid_xml, location);
        }

        const ActivePrefixSearch = struct {
            index: usize,
            found: bool,
        };

        fn findActivePrefix(
            self: *Self,
            prefix: []const u8,
            location: Location(config),
        ) ReadError!ActivePrefixSearch {
            var low: usize = 0;
            var high = self.namespace_state.active_prefixes.items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const binding_index = self.namespace_state.active_prefixes.items[middle];
                const binding = self.namespace_state.bindings.items[binding_index];
                const stored_prefix = self.namespace_state.bytes.items[binding.prefix_offset..][0..binding.prefix_len];
                try self.chargeNamespaceComparison(
                    prefix.len +| stored_prefix.len +| 1,
                    location,
                );
                switch (std.mem.order(u8, stored_prefix, prefix)) {
                    .lt => low = middle + 1,
                    .gt => high = middle,
                    .eq => return .{ .index = middle, .found = true },
                }
            }
            return .{ .index = low, .found = false };
        }

        fn expandedName(
            self: *const Self,
            raw: []const u8,
            parts: QNameParts,
            reference: NamespaceReference,
        ) ExpandedName {
            return .{
                .raw = raw,
                .prefix = parts.prefix,
                .local = parts.local,
                .namespace_uri = self.namespaceUri(reference),
            };
        }

        fn namespaceUri(self: *const Self, reference: NamespaceReference) ?[]const u8 {
            return switch (reference) {
                .none => null,
                .predefined_xml => xml_namespace_uri,
                .binding => |index| uri: {
                    const binding = self.namespace_state.bindings.items[index];
                    break :uri self.namespace_state.bytes.items[binding.uri_offset..][0..binding.uri_len];
                },
            };
        }

        fn chargeNamespaceComparison(
            self: *Self,
            amount: usize,
            location: Location(config),
        ) ReadError!void {
            if (!self.namespaceComparisonAllowed(amount)) {
                return self.failAt(.namespace_comparison_limit, .limit_exceeded, location);
            }
        }

        fn namespaceComparisonAllowed(self: *Self, amount: usize) bool {
            const remaining = self.options.namespace_limits.max_comparison_work -|
                self.namespace_state.comparison_work;
            if (amount > remaining) {
                return false;
            }
            self.namespace_state.comparison_work += amount;
            return true;
        }

        fn rejectDuplicateExpandedAttributes(self: *Self) ReadError!void {
            const attributes = self.event_attributes.items;
            if (attributes.len <= linear_duplicate_threshold) {
                for (attributes, 0..) |attribute, index| {
                    for (attributes[0..index], 0..) |previous, previous_index| {
                        try self.chargeNamespaceComparison(
                            expandedComparisonCost(attribute.name, previous.name),
                            self.currentLocation(),
                        );
                        if (expandedNamesEqual(attribute.name, previous.name)) {
                            return self.failRelated(
                                .duplicate_expanded_attribute,
                                .invalid_xml,
                                self.namespace_state.event_attribute_locations.items[index],
                                self.namespace_state.event_attribute_locations.items[previous_index],
                            );
                        }
                    }
                }
                return;
            }

            try self.ensureExpandedSortWork(attributes);
            std.sort.heap(
                usize,
                self.namespace_state.expanded_indices.items,
                self,
                expandedAttributeIndexLessThan,
            );
            const indices = self.namespace_state.expanded_indices.items;
            for (indices[1..], indices[0 .. indices.len - 1]) |index, previous_index| {
                const attribute = attributes[index];
                const previous = attributes[previous_index];
                try self.chargeNamespaceComparison(
                    expandedComparisonCost(attribute.name, previous.name),
                    self.currentLocation(),
                );
                if (expandedNamesEqual(attribute.name, previous.name)) {
                    return self.failRelated(
                        .duplicate_expanded_attribute,
                        .invalid_xml,
                        self.namespace_state.event_attribute_locations.items[index],
                        self.namespace_state.event_attribute_locations.items[previous_index],
                    );
                }
            }
        }

        fn expandedAttributeIndexLessThan(
            self: *Self,
            left_index: usize,
            right_index: usize,
        ) bool {
            const left = self.event_attributes.items[left_index].name;
            const right = self.event_attributes.items[right_index].name;
            const uri_order = optionalBytesOrder(left.namespace_uri, right.namespace_uri);
            if (uri_order != .eq) return uri_order == .lt;
            const local_order = std.mem.order(u8, left.local, right.local);
            if (local_order != .eq) return local_order == .lt;
            return left_index < right_index;
        }

        fn ensureExpandedSortWork(
            self: *Self,
            attributes: []const Attribute(config),
        ) ReadError!void {
            var max_uri_len: usize = 0;
            var max_local_len: usize = 0;
            for (attributes) |attribute| {
                max_uri_len = @max(
                    max_uri_len,
                    optionalBytesLength(attribute.name.namespace_uri),
                );
                max_local_len = @max(max_local_len, attribute.name.local.len);
            }
            var levels: usize = 1;
            var width = attributes.len;
            while (width > 1) : (levels +|= 1) width = (width + 1) / 2;
            // The factor bounds heap-sort comparisons; the final term covers adjacency checks.
            const comparison_bound = 8 *| attributes.len *| levels +| attributes.len;
            const cost_bound = 2 *| max_uri_len +| 2 *| max_local_len +| 2;
            const work_bound = comparison_bound *| cost_bound;
            const remaining = self.options.namespace_limits.max_comparison_work -|
                self.namespace_state.comparison_work;
            if (work_bound > remaining) {
                return self.fail(.namespace_comparison_limit, .limit_exceeded);
            }
        }

        fn prepareEventAttributes(self: *Self) ReadError!void {
            try self.rejectDuplicateAttributes();
            self.event_attributes.clearRetainingCapacity();
            self.event_attributes.ensureTotalCapacity(
                self.allocator,
                self.attribute_records.items.len,
            ) catch return self.failOutOfMemory();
            for (self.attribute_records.items) |record| {
                const raw_name = self.attributeRawName(record);
                const value_offset = record.name_offset + record.name_len;
                self.event_attributes.appendAssumeCapacity(.{
                    .name = nameFromRaw(config, raw_name),
                    .value = self.attribute_bytes.items[value_offset..][0..record.value_len],
                });
            }
        }

        fn rejectDuplicateAttributes(self: *Self) ReadError!void {
            const records = self.attribute_records.items;
            if (records.len <= linear_duplicate_threshold) {
                for (records, 0..) |record, index| {
                    for (records[0..index]) |previous| {
                        if (std.mem.eql(
                            u8,
                            self.attributeRawName(record),
                            self.attributeRawName(previous),
                        )) {
                            return self.failRelated(
                                .duplicate_attribute,
                                .invalid_xml,
                                record.start,
                                previous.start,
                            );
                        }
                    }
                }
                return;
            }

            std.sort.heap(
                AttributeRecord(config),
                records,
                self,
                attributeRecordNameLessThan,
            );
            for (records[1..], records[0 .. records.len - 1]) |record, previous| {
                if (std.mem.eql(
                    u8,
                    self.attributeRawName(record),
                    self.attributeRawName(previous),
                )) {
                    return self.failRelated(
                        .duplicate_attribute,
                        .invalid_xml,
                        record.start,
                        previous.start,
                    );
                }
            }
            std.sort.heap(
                AttributeRecord(config),
                records,
                {},
                attributeRecordSourceLessThan,
            );
        }

        fn attributeRecordNameLessThan(
            self: *Self,
            left: AttributeRecord(config),
            right: AttributeRecord(config),
        ) bool {
            return switch (std.mem.order(
                u8,
                self.attributeRawName(left),
                self.attributeRawName(right),
            )) {
                .lt => true,
                .gt => false,
                .eq => left.start.byte_offset < right.start.byte_offset,
            };
        }

        fn attributeRecordSourceLessThan(
            _: void,
            left: AttributeRecord(config),
            right: AttributeRecord(config),
        ) bool {
            return left.start.byte_offset < right.start.byte_offset;
        }

        fn attributeRawName(
            self: *const Self,
            record: AttributeRecord(config),
        ) []const u8 {
            return self.attribute_bytes.items[record.name_offset..][0..record.name_len];
        }

        fn compareAndConsumeEndName(self: *Self, run: []const u8) ReadError!void {
            const partial_remaining = std.math.sub(
                usize,
                self.options.limits.max_partial_token_bytes,
                self.token_name_len,
            ) catch unreachable;
            const qname_remaining = self.qnameRemaining(self.token_name_len);
            const accepted_len = @min(run.len, @min(partial_remaining, qname_remaining));
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
                if (self.token_name_len == self.options.limits.max_partial_token_bytes) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
        }

        fn compareDecodedEndName(self: *Self, len: usize) ReadError!void {
            const remaining = self.options.limits.max_partial_token_bytes - self.token_name_len;
            if (len > remaining) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            if (len > self.qnameRemaining(self.token_name_len)) {
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
            const raw = self.topRawName();
            if (self.end_mismatch_index == no_end_mismatch) {
                for (self.utf8_bytes[0..len], 0..) |byte, index| {
                    const name_index = self.token_name_len + index;
                    if (name_index >= raw.len or raw[name_index] != byte) {
                        self.end_mismatch_index = name_index;
                        break;
                    }
                }
            }
            self.token_name_len += len;
        }

        fn pendingUtf8ScalarLength(self: *const Self) error{InvalidUtf8}!usize {
            if (self.utf8_expected_len != 0) return self.utf8_expected_len;
            if (self.cursor == self.input.len) return error.InvalidUtf8;
            return utf8ExpectedLength(self.input[self.cursor]) orelse error.InvalidUtf8;
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
            if (comptime config.profile.hasNamespaces()) {
                var binding_index = self.namespace_state.bindings.items.len;
                while (binding_index > frame.namespace_binding_mark) {
                    binding_index -= 1;
                    const binding = self.namespace_state.bindings.items[binding_index];
                    std.debug.assert(
                        self.namespace_state.active_prefixes.items[binding.active_index] ==
                            binding_index,
                    );
                    if (binding.previous_binding) |previous| {
                        self.namespace_state.active_prefixes.items[binding.active_index] = previous;
                    } else {
                        _ = self.namespace_state.active_prefixes.orderedRemove(binding.active_index);
                    }
                }
                self.namespace_state.bindings.items.len = frame.namespace_binding_mark;
                self.namespace_state.bytes.items.len = frame.namespace_byte_mark;
            }
        }

        fn topFrame(self: *const Self) OpenElementFrame(config) {
            std.debug.assert(self.open_elements.items.len > 0);
            return self.open_elements.items[self.open_elements.items.len - 1];
        }

        fn topRawName(self: *const Self) []const u8 {
            const frame = self.topFrame();
            return self.open_names.items[frame.name_offset..][0..frame.name_len];
        }

        fn startTagBytes(self: *const Self) usize {
            const byte_count = self.source_byte_offset - self.token_start.byte_offset;
            return std.math.cast(usize, byte_count) orelse std.math.maxInt(usize);
        }

        fn startTagRemaining(self: *const Self) usize {
            return std.math.sub(
                usize,
                self.options.limits.max_start_tag_bytes,
                self.startTagBytes(),
            ) catch 0;
        }

        fn requireStartTagByte(self: *Self) ReadError!void {
            if (self.startTagRemaining() == 0) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn consumeStartTagByte(self: *Self, byte: u8) void {
            std.debug.assert(self.startTagRemaining() > 0);
            self.consumeByte(byte);
        }

        fn consumeStartTagRun(self: *Self, run: []const u8) void {
            std.debug.assert(run.len <= self.startTagRemaining());
            self.consumeRun(run);
        }

        fn consumeStartTagWhitespaceRun(self: *Self) ReadError!void {
            const start = self.cursor;
            var end = start;
            while (end < self.input.len and isXmlWhitespace(self.input[end])) {
                end += 1;
            }
            const run = self.input[start..end];
            const accepted_len = @min(run.len, self.startTagRemaining());
            self.consumeStartTagRun(run[0..accepted_len]);
            if (accepted_len != run.len) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
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
            if (comptime config.profile.hasNamespaces()) {
                const raw = self.topRawName();
                return self.expandedName(
                    raw,
                    qnameParts(raw).?,
                    self.topFrame().namespace_reference,
                );
            }
            return nameFromRaw(config, self.topRawName());
        }

        fn startElement(self: *const Self, empty: bool) StartElement(config) {
            if (comptime config.profile.hasNamespaces()) {
                return .{
                    .name = self.topName(),
                    .attributes = self.event_attributes.items,
                    .namespace_declarations = self.namespace_state.event_declarations.items,
                    .empty_element_syntax = empty,
                };
            }
            return .{
                .name = self.topName(),
                .attributes = self.event_attributes.items,
                .empty_element_syntax = empty,
            };
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

const ParsedDeclaration = struct {
    version_offset: usize,
    version_len: usize,
    encoding_offset: usize = 0,
    encoding_len: usize = 0,
    standalone: bool = false,
    standalone_declared: bool = false,
};

const DeclarationParse = union(enum) {
    parsed: ParsedDeclaration,
    malformed: usize,
    unsupported_version: usize,
    unsupported_encoding: usize,
};

const ByteRange = struct {
    offset: usize,
    len: usize,
};

fn parseXmlDeclaration(bytes: []const u8) DeclarationParse {
    var index: usize = 0;
    if (!skipRequiredXmlWhitespace(bytes, &index)) return .{ .malformed = index };
    if (!consumeLiteral(bytes, &index, "version")) return .{ .malformed = index };
    if (!consumeEquals(bytes, &index)) return .{ .malformed = index };
    const version = consumeQuoted(bytes, &index) orelse return .{ .malformed = index };
    const version_bytes = bytes[version.offset..][0..version.len];
    if (!isXml10VersionNumber(version_bytes)) {
        if (isDottedVersionNumber(version_bytes)) {
            return .{ .unsupported_version = version.offset };
        }
        return .{ .malformed = version.offset };
    }

    var parsed: ParsedDeclaration = .{
        .version_offset = version.offset,
        .version_len = version.len,
    };
    if (index == bytes.len) return .{ .parsed = parsed };
    if (!skipRequiredXmlWhitespace(bytes, &index)) return .{ .malformed = index };
    if (index == bytes.len) return .{ .parsed = parsed };

    if (startsWithLiteral(bytes, index, "encoding")) {
        _ = consumeLiteral(bytes, &index, "encoding");
        if (!consumeEquals(bytes, &index)) return .{ .malformed = index };
        const encoding = consumeQuoted(bytes, &index) orelse return .{ .malformed = index };
        const encoding_bytes = bytes[encoding.offset..][0..encoding.len];
        if (!isEncodingName(encoding_bytes)) return .{ .malformed = encoding.offset };
        if (!std.ascii.eqlIgnoreCase(encoding_bytes, "UTF-8")) {
            return .{ .unsupported_encoding = encoding.offset };
        }
        parsed.encoding_offset = encoding.offset;
        parsed.encoding_len = encoding.len;
        if (index == bytes.len) return .{ .parsed = parsed };
        if (!skipRequiredXmlWhitespace(bytes, &index)) return .{ .malformed = index };
        if (index == bytes.len) return .{ .parsed = parsed };
    }

    if (!consumeLiteral(bytes, &index, "standalone")) return .{ .malformed = index };
    if (!consumeEquals(bytes, &index)) return .{ .malformed = index };
    const standalone = consumeQuoted(bytes, &index) orelse return .{ .malformed = index };
    const standalone_bytes = bytes[standalone.offset..][0..standalone.len];
    if (std.mem.eql(u8, standalone_bytes, "yes")) {
        parsed.standalone = true;
    } else if (!std.mem.eql(u8, standalone_bytes, "no")) {
        return .{ .malformed = standalone.offset };
    }
    parsed.standalone_declared = true;
    if (index == bytes.len) return .{ .parsed = parsed };
    if (!skipRequiredXmlWhitespace(bytes, &index) or index != bytes.len) {
        return .{ .malformed = index };
    }
    return .{ .parsed = parsed };
}

fn skipRequiredXmlWhitespace(bytes: []const u8, index: *usize) bool {
    const start = index.*;
    while (index.* < bytes.len and isXmlWhitespace(bytes[index.*])) index.* += 1;
    return index.* != start;
}

fn skipOptionalXmlWhitespace(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and isXmlWhitespace(bytes[index.*])) index.* += 1;
}

fn startsWithLiteral(bytes: []const u8, index: usize, literal: []const u8) bool {
    return literal.len <= bytes.len -| index and
        std.mem.eql(u8, bytes[index..][0..literal.len], literal);
}

fn consumeLiteral(bytes: []const u8, index: *usize, literal: []const u8) bool {
    if (!startsWithLiteral(bytes, index.*, literal)) return false;
    index.* += literal.len;
    return true;
}

fn consumeEquals(bytes: []const u8, index: *usize) bool {
    skipOptionalXmlWhitespace(bytes, index);
    if (index.* == bytes.len or bytes[index.*] != '=') return false;
    index.* += 1;
    skipOptionalXmlWhitespace(bytes, index);
    return true;
}

fn consumeQuoted(bytes: []const u8, index: *usize) ?ByteRange {
    if (index.* == bytes.len) return null;
    const quote = bytes[index.*];
    if (quote != '\'' and quote != '"') return null;
    index.* += 1;
    const start = index.*;
    while (index.* < bytes.len and bytes[index.*] != quote) index.* += 1;
    if (index.* == bytes.len) return null;
    const result: ByteRange = .{ .offset = start, .len = index.* - start };
    index.* += 1;
    return result;
}

fn isXml10VersionNumber(bytes: []const u8) bool {
    if (bytes.len < 3 or bytes[0] != '1' or bytes[1] != '.') return false;
    for (bytes[2..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isDottedVersionNumber(bytes: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, bytes, '.') orelse return false;
    if (dot == 0 or dot + 1 == bytes.len) return false;
    for (bytes[0..dot]) |byte| if (!std.ascii.isDigit(byte)) return false;
    for (bytes[dot + 1 ..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isEncodingName(bytes: []const u8) bool {
    if (bytes.len == 0 or !std.ascii.isAlphabetic(bytes[0])) return false;
    for (bytes[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn isAsciiCaseInsensitiveXml(bytes: []const u8) bool {
    return bytes.len == 3 and std.ascii.eqlIgnoreCase(bytes, "xml");
}

fn qnameParts(raw: []const u8) ?QNameParts {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse
        return .{ .prefix = null, .local = raw };
    if (colon == 0 or colon + 1 == raw.len) return null;
    if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':') != null) return null;
    if (!isNcNameStart(raw[colon + 1 ..])) return null;
    return .{
        .prefix = raw[0..colon],
        .local = raw[colon + 1 ..],
    };
}

fn qnameErrorIndex(raw: []const u8) usize {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return 0;
    if (colon == 0) return 0;
    if (colon + 1 == raw.len) return colon;
    if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':')) |second| return second;
    return if (isNcNameStart(raw[colon + 1 ..])) colon else colon + 1;
}

fn isNcNameStart(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return false;
    if (sequence_len > bytes.len) return false;
    const codepoint = std.unicode.utf8Decode(bytes[0..sequence_len]) catch return false;
    return codepoint != ':' and isXml10NameStart(codepoint);
}

fn namespaceDeclarationPrefix(raw: []const u8, parts: QNameParts) ?[]const u8 {
    if (std.mem.eql(u8, raw, "xmlns")) return "";
    if (parts.prefix) |prefix| {
        if (std.mem.eql(u8, prefix, "xmlns")) return parts.local;
    }
    return null;
}

fn expandedComparisonCost(left: ExpandedName, right: ExpandedName) usize {
    return optionalBytesLength(left.namespace_uri) +|
        optionalBytesLength(right.namespace_uri) +|
        left.local.len +|
        right.local.len +| 2;
}

fn optionalBytesLength(value: ?[]const u8) usize {
    return if (value) |bytes| bytes.len else 0;
}

fn optionalBytesOrder(left: ?[]const u8, right: ?[]const u8) std.math.Order {
    if (left) |left_bytes| {
        if (right) |right_bytes| return std.mem.order(u8, left_bytes, right_bytes);
        return .gt;
    }
    return if (right == null) .eq else .lt;
}

fn expandedNamesEqual(left: ExpandedName, right: ExpandedName) bool {
    return optionalBytesOrder(left.namespace_uri, right.namespace_uri) == .eq and
        std.mem.eql(u8, left.local, right.local);
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

fn isOrdinaryAttributeValueByte(byte: u8, quote: u8) bool {
    return byte >= ' ' and byte < 0x80 and byte != quote and byte != '&' and byte != '<';
}

fn isXml10Char(codepoint: u21) bool {
    return codepoint == 0x9 or codepoint == 0xa or codepoint == 0xd or
        (codepoint >= 0x20 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

fn hasForbiddenAsciiControl(bytes: []const u8) bool {
    var index: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const space: Vector = @splat(0x20);
        const tab: Vector = @splat('\t');
        const line_feed: Vector = @splat('\n');
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const block: Vector = bytes[index..][0..vector_len].*;
            const forbidden = (block < space) & (block != tab) & (block != line_feed);
            if (@reduce(.Or, forbidden)) return true;
        }
    }
    for (bytes[index..]) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\n') return true;
    }
    return false;
}

const ContentStructureScan = struct {
    delimiter_index: usize,
    has_non_ascii: bool,
};

fn contentStartsUnicodeDense(bytes: []const u8) bool {
    for (bytes[0..@min(bytes.len, 8)]) |byte| if (byte >= 0x80) return true;
    return false;
}

noinline fn scanContentStructure(bytes: []const u8) ContentStructureScan {
    var index: usize = 0;
    var has_non_ascii = false;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const mask: Vector = @splat(0x80);
        const less_than: Vector = @splat('<');
        const ampersand: Vector = @splat('&');
        const carriage_return: Vector = @splat('\r');
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const block: Vector = bytes[index..][0..vector_len].*;
            const delimiter = (block == less_than) | (block == ampersand) |
                (block == carriage_return);
            if (@reduce(.Or, delimiter)) {
                for (bytes[index..][0..vector_len], 0..) |byte, relative| {
                    if (byte == '<' or byte == '&' or byte == '\r') {
                        return .{
                            .delimiter_index = index + relative,
                            .has_non_ascii = has_non_ascii,
                        };
                    }
                    has_non_ascii = has_non_ascii or byte >= 0x80;
                }
                unreachable;
            }
            has_non_ascii = has_non_ascii or @reduce(.Or, block & mask == mask);
        }
    }
    for (bytes[index..], index..) |byte, position| {
        if (byte == '<' or byte == '&' or byte == '\r') {
            return .{ .delimiter_index = position, .has_non_ascii = has_non_ascii };
        }
        has_non_ascii = has_non_ascii or byte >= 0x80;
    }
    return .{ .delimiter_index = bytes.len, .has_non_ascii = has_non_ascii };
}

fn hasNonAscii(bytes: []const u8) bool {
    var index: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const mask: Vector = @splat(0x80);
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const block: Vector = bytes[index..][0..vector_len].*;
            if (@reduce(.Or, block & mask == mask)) return true;
        }
    }
    for (bytes[index..]) |byte| if (byte >= 0x80) return true;
    return false;
}

noinline fn utf8AndXmlControlsValid(bytes: []const u8) bool {
    var index: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const c2: Vector = @splat(0xc2);
        const e0: Vector = @splat(0xe0);
        const ed: Vector = @splat(0xed);
        const f0: Vector = @splat(0xf0);
        const f4: Vector = @splat(0xf4);
        const ff: Vector = @splat(0xff);
        const fe: Vector = @splat(0xfe);
        const bf: Vector = @splat(0xbf);
        const continuation_low: Vector = @splat(0x80);
        const continuation_high: Vector = @splat(0xbf);
        const a0: Vector = @splat(0xa0);
        const nine_f: Vector = @splat(0x9f);
        const nine_zero: Vector = @splat(0x90);
        const eight_f: Vector = @splat(0x8f);
        const space: Vector = @splat(0x20);
        const tab: Vector = @splat('\t');
        const line_feed: Vector = @splat('\n');

        while (index < @min(bytes.len, 3)) : (index += 1) {
            if (!utf8XmlByteValid(bytes, index)) return false;
        }
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const current: Vector = bytes[index..][0..vector_len].*;
            const previous1: Vector = bytes[index - 1 ..][0..vector_len].*;
            const previous2: Vector = bytes[index - 2 ..][0..vector_len].*;
            const previous3: Vector = bytes[index - 3 ..][0..vector_len].*;

            const continuation = (current >= continuation_low) &
                (current <= continuation_high);
            const expected = ((previous1 >= c2) & (previous1 <= f4)) |
                ((previous2 >= e0) & (previous2 <= f4)) |
                ((previous3 >= f0) & (previous3 <= f4));
            const invalid_leader = ((current >= @as(Vector, @splat(0xc0))) &
                (current < c2)) | (current > f4);
            const invalid_boundary = ((previous1 == e0) & (current < a0)) |
                ((previous1 == ed) & (current > nine_f)) |
                ((previous1 == f0) & (current < nine_zero)) |
                ((previous1 == f4) & (current > eight_f));
            const forbidden_noncharacter = (previous2 == @as(Vector, @splat(0xef))) &
                (previous1 == bf) & ((current == fe) | (current == ff));
            const forbidden_control = (current < space) &
                (current != tab) &
                (current != line_feed);
            if (@reduce(.Or, (continuation != expected) | invalid_leader |
                invalid_boundary | forbidden_noncharacter | forbidden_control))
            {
                return false;
            }
        }
    }
    while (index < bytes.len) : (index += 1) {
        if (!utf8XmlByteValid(bytes, index)) return false;
    }
    if (bytes.len > 0 and isUtf8Leader(bytes[bytes.len - 1])) return false;
    if (bytes.len > 1 and isUtf8ThreeOrFourByteLeader(bytes[bytes.len - 2])) return false;
    if (bytes.len > 2 and isUtf8FourByteLeader(bytes[bytes.len - 3])) return false;
    return true;
}

fn utf8XmlByteValid(bytes: []const u8, index: usize) bool {
    const byte = bytes[index];
    const continuation = byte >= 0x80 and byte <= 0xbf;
    const expected = (index >= 1 and isUtf8Leader(bytes[index - 1])) or
        (index >= 2 and isUtf8ThreeOrFourByteLeader(bytes[index - 2])) or
        (index >= 3 and isUtf8FourByteLeader(bytes[index - 3]));
    if (continuation != expected or byte == 0xc0 or byte == 0xc1 or byte > 0xf4) return false;
    if (index >= 1) {
        const previous = bytes[index - 1];
        if ((previous == 0xe0 and byte < 0xa0) or
            (previous == 0xed and byte > 0x9f) or
            (previous == 0xf0 and byte < 0x90) or
            (previous == 0xf4 and byte > 0x8f))
        {
            return false;
        }
    }
    if (index >= 2 and bytes[index - 2] == 0xef and bytes[index - 1] == 0xbf and
        (byte == 0xbe or byte == 0xbf)) return false;
    return byte >= 0x20 or byte == '\t' or byte == '\n';
}

fn isUtf8Leader(byte: u8) bool {
    return byte >= 0xc2 and byte <= 0xf4;
}

fn isUtf8ThreeOrFourByteLeader(byte: u8) bool {
    return byte >= 0xe0 and byte <= 0xf4;
}

fn isUtf8FourByteLeader(byte: u8) bool {
    return byte >= 0xf0 and byte <= 0xf4;
}

test "[unit] - [content SIMD]: forbidden-control scan matches scalar boundaries" {
    const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
    var storage: [2 * vector_len + 1]u8 = undefined;
    const lengths = [_]usize{ vector_len - 1, vector_len, vector_len + 1, storage.len };
    for (lengths) |length| {
        const bytes = storage[0..length];
        @memset(bytes, 'x');
        try std.testing.expect(!hasForbiddenAsciiControl(bytes));
        for (0..length) |position| {
            for (0..256) |value| {
                bytes[position] = @intCast(value);
                const expected = value < 0x20 and value != '\t' and value != '\n';
                try std.testing.expectEqual(expected, hasForbiddenAsciiControl(bytes));
            }
            bytes[position] = 'x';
        }
    }
}

test "[unit] - [content SIMD]: UTF-8 and XML-control scan matches reference" {
    const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
    var storage: [2 * vector_len + 7]u8 = undefined;
    const pattern = "a\xc3\xa9\xce\xbb\xf0\x9f\x99\x82";
    for (&storage, 0..) |*byte, index| byte.* = pattern[index % pattern.len];

    const lengths = [_]usize{
        0,
        1,
        vector_len - 1,
        vector_len,
        vector_len + 1,
        2 * vector_len - 1,
        2 * vector_len,
        storage.len,
    };
    for (lengths) |length| {
        for (0..length) |position| {
            const original = storage[position];
            for (0..256) |value| {
                storage[position] = @intCast(value);
                const bytes = storage[0..length];
                const expected = std.unicode.utf8ValidateSlice(bytes) and
                    !hasForbiddenAsciiControl(bytes) and
                    std.mem.indexOf(u8, bytes, "\xef\xbf\xbe") == null and
                    std.mem.indexOf(u8, bytes, "\xef\xbf\xbf") == null;
                try std.testing.expectEqual(expected, utf8AndXmlControlsValid(bytes));
            }
            storage[position] = original;
        }
    }

    var prng = std.Random.DefaultPrng.init(0x757466385f786d6c);
    const random = prng.random();
    for (0..10_000) |_| {
        const length = random.intRangeAtMost(usize, 0, storage.len);
        random.bytes(storage[0..length]);
        const bytes = storage[0..length];
        const expected = std.unicode.utf8ValidateSlice(bytes) and
            !hasForbiddenAsciiControl(bytes) and
            std.mem.indexOf(u8, bytes, "\xef\xbf\xbe") == null and
            std.mem.indexOf(u8, bytes, "\xef\xbf\xbf") == null;
        try std.testing.expectEqual(expected, utf8AndXmlControlsValid(bytes));
    }
}

test "[unit] - [content SIMD]: structural scan matches scalar boundaries" {
    const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
    var storage: [2 * vector_len + 1]u8 = undefined;
    const lengths = [_]usize{ vector_len - 1, vector_len, vector_len + 1, storage.len };
    for (lengths) |length| {
        const bytes = storage[0..length];
        @memset(bytes, 'x');
        for (0..length) |position| {
            for (0..256) |value| {
                bytes[position] = @intCast(value);
                var expected_index = length;
                var expected_non_ascii = false;
                for (bytes, 0..) |byte, index| {
                    if (byte == '<' or byte == '&' or byte == '\r') {
                        expected_index = index;
                        break;
                    }
                    expected_non_ascii = expected_non_ascii or byte >= 0x80;
                }
                const observed = scanContentStructure(bytes);
                try std.testing.expectEqual(expected_index, observed.delimiter_index);
                try std.testing.expectEqual(expected_non_ascii, observed.has_non_ascii);
            }
            bytes[position] = 'x';
        }
    }
}

fn isXml10NameStart(codepoint: u21) bool {
    return codepoint == ':' or
        (codepoint >= 'A' and codepoint <= 'Z') or
        codepoint == '_' or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0xc0 and codepoint <= 0xd6) or
        (codepoint >= 0xd8 and codepoint <= 0xf6) or
        (codepoint >= 0xf8 and codepoint <= 0x2ff) or
        (codepoint >= 0x370 and codepoint <= 0x37d) or
        (codepoint >= 0x37f and codepoint <= 0x1fff) or
        (codepoint >= 0x200c and codepoint <= 0x200d) or
        (codepoint >= 0x2070 and codepoint <= 0x218f) or
        (codepoint >= 0x2c00 and codepoint <= 0x2fef) or
        (codepoint >= 0x3001 and codepoint <= 0xd7ff) or
        (codepoint >= 0xf900 and codepoint <= 0xfdcf) or
        (codepoint >= 0xfdf0 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0xeffff);
}

fn isXml10NameChar(codepoint: u21) bool {
    return isXml10NameStart(codepoint) or codepoint == '-' or codepoint == '.' or
        (codepoint >= '0' and codepoint <= '9') or codepoint == 0xb7 or
        (codepoint >= 0x300 and codepoint <= 0x36f) or
        (codepoint >= 0x203f and codepoint <= 0x2040);
}

fn probeUtf8(bytes: []const u8) Utf8Probe {
    std.debug.assert(bytes.len > 0);
    const lead = bytes[0];
    const expected: u3 = if (lead < 0x80)
        1
    else if (lead >= 0xc2 and lead <= 0xdf)
        2
    else if (lead >= 0xe0 and lead <= 0xef)
        3
    else if (lead >= 0xf0 and lead <= 0xf4)
        4
    else
        return .{ .invalid = 0 };
    if (bytes.len < expected) {
        for (bytes[1..], 1..) |byte, index| {
            if (byte < 0x80 or byte > 0xbf) return .{ .invalid = index };
            if (index == 1 and !validUtf8SecondByte(lead, byte)) {
                return .{ .invalid = index };
            }
        }
        return .incomplete;
    }
    for (bytes[1..expected], 1..) |byte, index| {
        if (byte < 0x80 or byte > 0xbf) return .{ .invalid = index };
        if (index == 1 and !validUtf8SecondByte(lead, byte)) {
            return .{ .invalid = index };
        }
    }
    const codepoint = std.unicode.utf8Decode(bytes[0..expected]) catch unreachable;
    return .{ .scalar = .{ .codepoint = codepoint, .len = expected } };
}

fn validUtf8SecondByte(lead: u8, byte: u8) bool {
    if (lead == 0xe0) return byte >= 0xa0;
    if (lead == 0xed) return byte <= 0x9f;
    if (lead == 0xf0) return byte >= 0x90;
    if (lead == 0xf4) return byte <= 0x8f;
    return true;
}

fn utf8ExpectedLength(lead: u8) ?u3 {
    if (lead < 0x80) return 1;
    if (lead >= 0xc2 and lead <= 0xdf) return 2;
    if (lead >= 0xe0 and lead <= 0xef) return 3;
    if (lead >= 0xf0 and lead <= 0xf4) return 4;
    return null;
}

fn referenceDigit(byte: u8, kind: ReferenceKind) ?u32 {
    return switch (kind) {
        .decimal => if (byte >= '0' and byte <= '9') byte - '0' else null,
        .hexadecimal => if (byte >= '0' and byte <= '9')
            byte - '0'
        else if (byte >= 'a' and byte <= 'f')
            byte - 'a' + 10
        else if (byte >= 'A' and byte <= 'F')
            byte - 'A' + 10
        else
            null,
    };
}

fn predefinedEntity(name: []const u8, source_len: usize) ?[]const u8 {
    if (source_len != name.len) return null;
    if (std.mem.eql(u8, name, "amp")) return "&";
    if (std.mem.eql(u8, name, "lt")) return "<";
    if (std.mem.eql(u8, name, "gt")) return ">";
    if (std.mem.eql(u8, name, "apos")) return "'";
    if (std.mem.eql(u8, name, "quot")) return "\"";
    return null;
}

fn locationWithByteDelta(
    comptime config: Config,
    location: Location(config),
    delta: usize,
) Location(config) {
    var result = location;
    result.byte_offset += delta;
    if (config.diagnostic_location == .line_column) result.byte_column += delta;
    return result;
}

fn nameFromRaw(comptime config: Config, raw: []const u8) Name(config) {
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
