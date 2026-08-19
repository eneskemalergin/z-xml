//! Parses and stores XML internal and external DTD declarations.
//!
//! Stored strings use offsets into one owned arena so growth cannot invalidate declarations.

const std = @import("std");

pub const XmlVersion = enum {
    xml10,
    xml11,
};

pub const AttributeType = enum {
    cdata,
    id,
    idref,
    idrefs,
    entity,
    entities,
    nmtoken,
    nmtokens,
    enumeration,
    notation,

    pub fn isTokenized(self: AttributeType) bool {
        return self != .cdata;
    }
};

pub const DefaultKind = enum {
    required,
    implied,
    value,
    fixed,
};

/// Finite limits for DTD storage, grammar work, lookup work, and entity expansion.
pub const Limits = struct {
    /// Maximum decoded bytes in one document type declaration.
    max_dtd_bytes: usize = 1024 * 1024,
    /// Maximum markup declarations processed from the internal subset and parameter entities.
    max_declarations: usize = 4096,
    /// Maximum cumulative decoded bytes in markup declarations.
    max_declaration_bytes: usize = 1024 * 1024,
    /// Maximum retained element declarations.
    max_element_declarations: usize = 1024,
    /// Maximum retained attribute declarations.
    max_attribute_declarations: usize = 4096,
    /// Maximum retained general and parameter entity declarations.
    max_entity_declarations: usize = 1024,
    /// Maximum retained notation declarations.
    max_notation_declarations: usize = 1024,
    /// Maximum nested content-model group depth.
    max_group_depth: usize = 256,
    /// Maximum cumulative content-model and attribute-type grammar nodes.
    max_grammar_nodes: usize = 64 * 1024,
    /// Maximum cumulative normalized replacement and default bytes.
    max_entity_replacement_bytes: usize = 1024 * 1024,
    /// Maximum active parameter or general entity depth.
    max_active_entity_depth: usize = 64,
    /// Maximum cumulative parameter and general entity reference count.
    max_entity_references: usize = 1024 * 1024,
    /// Maximum cumulative bytes included from entity replacement text.
    max_expanded_bytes: usize = 8 * 1024 * 1024,
    /// Maximum expanded bytes per entity-reference source byte after the minimum threshold.
    max_expansion_ratio: usize = 100,
    /// Expanded-byte count at or below which ratio enforcement remains disabled.
    expansion_ratio_minimum_bytes: usize = 4096,
    /// Maximum cumulative weighted DTD name-comparison work.
    max_comparison_work: usize = 8 * 1024 * 1024,

    /// Returns whether every required limit has a usable nonzero value.
    pub fn validate(self: Limits) bool {
        return self.max_dtd_bytes > 0 and
            self.max_declarations > 0 and
            self.max_declaration_bytes > 0 and
            self.max_element_declarations > 0 and
            self.max_attribute_declarations > 0 and
            self.max_entity_declarations > 0 and
            self.max_notation_declarations > 0 and
            self.max_group_depth > 0 and
            self.max_grammar_nodes > 0 and
            self.max_entity_replacement_bytes > 0 and
            self.max_active_entity_depth > 0 and
            self.max_entity_references > 0 and
            self.max_expanded_bytes > 0 and
            self.max_expansion_ratio > 0 and
            self.max_comparison_work > 0;
    }
};

pub const ErrorCode = enum {
    malformed_doctype,
    malformed_declaration,
    malformed_element_declaration,
    malformed_attribute_list,
    malformed_entity_declaration,
    malformed_notation_declaration,
    malformed_comment,
    malformed_processing_instruction,
    dtd_bytes_limit,
    undeclared_parameter_entity,
    recursive_parameter_entity,
    external_subset_unsupported,
    declaration_limit,
    declaration_bytes_limit,
    element_declaration_limit,
    attribute_declaration_limit,
    entity_declaration_limit,
    notation_declaration_limit,
    grammar_depth_limit,
    grammar_node_limit,
    replacement_bytes_limit,
    entity_depth_limit,
    entity_reference_limit,
    expanded_bytes_limit,
    expansion_ratio_limit,
    comparison_work_limit,
};

pub const ParseError = error{
    InvalidDtd,
    UnsupportedFeature,
    LimitExceeded,
    OutOfMemory,
    ResolverFailed,
    ReadFailed,
    Cancelled,
};

pub const ExternalKind = enum { subset, parameter_entity };

pub const ExternalRequest = struct {
    kind: ExternalKind,
    name: ?[]const u8 = null,
    public_id: ?[]const u8 = null,
    system_id: []const u8,
    base_id: ?[]const u8 = null,
    inclusion_source_id: u32 = 0,
    inclusion_offset: usize = 0,
};

pub const ExternalContent = struct {
    bytes: []const u8,
    base_id: ?[]const u8 = null,
    source_id: u32,
};

pub const ExternalResult = union(enum) {
    content: ExternalContent,
    skipped,
};

pub const ExternalProvider = struct {
    context: ?*anyopaque,
    resolveFn: *const fn (?*anyopaque, ExternalRequest) ParseError!ExternalResult,

    pub fn resolve(self: ExternalProvider, request: ExternalRequest) ParseError!ExternalResult {
        return self.resolveFn(self.context, request);
    }
};

pub const Failure = struct {
    code: ErrorCode,
    offset: usize,
    source_id: u32 = 0,
};

pub const StoredString = struct {
    offset: usize,
    len: usize,
};

pub const DeclarationLocation = struct {
    source_id: u32 = 0,
    offset: usize = 0,
};

pub const ContentKind = enum {
    empty,
    any,
    mixed,
    children,
};

pub const ExternalId = struct {
    public_id: ?StoredString = null,
    system_id: ?StoredString = null,
};

pub const ElementDeclaration = struct {
    name: StoredString,
    content_kind: ContentKind,
    content_spec: ?StoredString = null,
    location: DeclarationLocation,
    declared_external: bool = false,
};

pub const AttributeDeclaration = struct {
    element_name: StoredString,
    name: StoredString,
    attribute_type: AttributeType,
    default_kind: DefaultKind,
    default_value: ?StoredString,
    allowed_values: ?StoredString = null,
    order: usize,
    location: DeclarationLocation,
    declared_external: bool = false,
};

pub const EntityDeclaration = struct {
    name: StoredString,
    name_hash: u64,
    value: ?StoredString,
    external_id: ExternalId = .{},
    parameter: bool,
    unparsed: bool = false,
    notation_name: ?StoredString = null,
    base_id: ?StoredString = null,
    declared_external: bool = false,
    location: DeclarationLocation,
};

pub const NotationDeclaration = struct {
    name: StoredString,
    external_id: ExternalId,
    location: DeclarationLocation,
};

pub const ReportKind = enum {
    element,
    attribute_list,
    parsed_entity,
    notation,
    unparsed_entity,
    comment,
    processing_instruction,
    skipped_external,
};

pub const Report = struct {
    kind: ReportKind,
    index: usize,
    name: ?StoredString = null,
};

const Misc = struct {
    first: StoredString,
    second: ?StoredString = null,
    location: DeclarationLocation,
};

pub const SkippedExternal = struct {
    kind: ExternalKind,
    name: ?StoredString = null,
    public_id: ?StoredString = null,
    system_id: StoredString,
    offset: usize,
};

const Source = struct {
    storage: enum { subset, arena, borrowed },
    offset: usize,
    len: usize,
    bytes: []const u8 = &.{},
    base_id: ?[]const u8 = null,
    source_id: u32 = 0,
    cursor: usize = 0,
    entity_index: ?usize = null,
    reference_offset: usize = 0,
    external: bool = false,
    boundary_space: bool = false,
};

pub const State = struct {
    version: XmlVersion = .xml10,
    doctype_bytes: std.ArrayList(u8) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    elements: std.ArrayList(ElementDeclaration) = .empty,
    attributes: std.ArrayList(AttributeDeclaration) = .empty,
    entities: std.ArrayList(EntityDeclaration) = .empty,
    notations: std.ArrayList(NotationDeclaration) = .empty,
    reports: std.ArrayList(Report) = .empty,
    misc: std.ArrayList(Misc) = .empty,
    skipped_external: std.ArrayList(SkippedExternal) = .empty,
    nesting_violations: std.ArrayList(DeclarationLocation) = .empty,
    root_name: ?StoredString = null,
    external_id: ExternalId = .{},
    failure: ?Failure = null,
    comparison_work: usize = 0,
    declaration_bytes: usize = 0,
    declaration_count: usize = 0,
    grammar_nodes: usize = 0,
    entity_references: usize = 0,
    entity_reference_bytes: usize = 0,
    expanded_bytes: usize = 0,
    replacement_bytes: usize = 0,
    parameter_reference_seen: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.doctype_bytes.deinit(allocator);
        self.bytes.deinit(allocator);
        self.elements.deinit(allocator);
        self.attributes.deinit(allocator);
        self.entities.deinit(allocator);
        self.notations.deinit(allocator);
        self.reports.deinit(allocator);
        self.misc.deinit(allocator);
        self.skipped_external.deinit(allocator);
        self.nesting_violations.deinit(allocator);
        self.* = .{};
    }

    pub fn clearRetainingCapacity(self: *State) void {
        self.doctype_bytes.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        self.elements.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
        self.entities.clearRetainingCapacity();
        self.notations.clearRetainingCapacity();
        self.reports.clearRetainingCapacity();
        self.misc.clearRetainingCapacity();
        self.skipped_external.clearRetainingCapacity();
        self.nesting_violations.clearRetainingCapacity();
        self.root_name = null;
        self.external_id = .{};
        self.failure = null;
        self.comparison_work = 0;
        self.declaration_bytes = 0;
        self.declaration_count = 0;
        self.grammar_nodes = 0;
        self.entity_references = 0;
        self.entity_reference_bytes = 0;
        self.expanded_bytes = 0;
        self.replacement_bytes = 0;
        self.parameter_reference_seen = false;
        self.version = .xml10;
    }

    pub fn capacity(self: *const State) usize {
        return self.doctype_bytes.capacity +|
            self.bytes.capacity +|
            self.elements.capacity *| @sizeOf(ElementDeclaration) +|
            self.attributes.capacity *| @sizeOf(AttributeDeclaration) +|
            self.entities.capacity *| @sizeOf(EntityDeclaration) +|
            self.notations.capacity *| @sizeOf(NotationDeclaration) +|
            self.reports.capacity *| @sizeOf(Report) +|
            self.misc.capacity *| @sizeOf(Misc) +|
            self.skipped_external.capacity *| @sizeOf(SkippedExternal) +|
            self.nesting_violations.capacity *| @sizeOf(DeclarationLocation);
    }

    pub fn notationCapacity(self: *const State) usize {
        return self.notations.capacity *| @sizeOf(NotationDeclaration);
    }

    pub fn string(self: *const State, stored: StoredString) []const u8 {
        return self.bytes.items[stored.offset..][0..stored.len];
    }

    pub fn rootName(self: *const State) []const u8 {
        return self.string(self.root_name.?);
    }

    pub fn parseDoctypeHeader(self: *State, allocator: std.mem.Allocator) ParseError!void {
        self.failure = null;
        const bytes = self.doctype_bytes.items;
        var cursor: usize = 0;
        if (!requireWhitespace(bytes, &cursor)) {
            return self.setInvalid(.malformed_doctype, cursor);
        }
        const root_start = cursor;
        const root = scanName(bytes, &cursor) orelse
            return self.setInvalid(.malformed_doctype, cursor);
        var public_id: ?[]const u8 = null;
        var system_id: ?[]const u8 = null;
        skipWhitespace(bytes, &cursor);
        if (startsKeyword(bytes, cursor, "SYSTEM")) {
            cursor += "SYSTEM".len;
            if (!requireWhitespace(bytes, &cursor)) {
                return self.setInvalid(.malformed_doctype, cursor);
            }
            const system = scanQuoted(bytes, &cursor) orelse
                return self.setInvalid(.malformed_doctype, cursor);
            system_id = system;
            skipWhitespace(bytes, &cursor);
        } else if (startsKeyword(bytes, cursor, "PUBLIC")) {
            cursor += "PUBLIC".len;
            if (!requireWhitespace(bytes, &cursor)) {
                return self.setInvalid(.malformed_doctype, cursor);
            }
            const public = scanQuoted(bytes, &cursor) orelse
                return self.setInvalid(.malformed_doctype, cursor);
            if (!validPublicId(public)) return self.setInvalid(.malformed_doctype, cursor);
            public_id = public;
            if (!requireWhitespace(bytes, &cursor)) {
                return self.setInvalid(.malformed_doctype, cursor);
            }
            const system = scanQuoted(bytes, &cursor) orelse
                return self.setInvalid(.malformed_doctype, cursor);
            system_id = system;
            skipWhitespace(bytes, &cursor);
        }
        if (cursor + 1 != bytes.len or (bytes[cursor] != '[' and bytes[cursor] != '>')) {
            return self.setInvalid(.malformed_doctype, cursor);
        }
        self.root_name = try self.store(allocator, bytes[root_start..][0..root.len]);
        self.external_id.public_id = if (public_id) |value|
            try self.store(allocator, value)
        else
            null;
        self.external_id.system_id = if (system_id) |value|
            try self.store(allocator, value)
        else
            null;
    }

    pub fn discardDoctypeHeader(self: *State) void {
        self.bytes.clearRetainingCapacity();
        self.root_name = null;
        self.external_id = .{};
    }

    pub fn reportName(self: *const State, report: Report) []const u8 {
        if (report.name) |name| return self.string(name);
        return switch (report.kind) {
            .element => self.string(self.elements.items[report.index].name),
            .parsed_entity, .unparsed_entity => self.string(self.entities.items[report.index].name),
            .notation => self.string(self.notations.items[report.index].name),
            .processing_instruction => self.string(self.misc.items[report.index].first),
            .comment => "",
            .attribute_list, .skipped_external => unreachable,
        };
    }

    pub fn reportData(self: *const State, report: Report) []const u8 {
        return switch (report.kind) {
            .comment => self.string(self.misc.items[report.index].first),
            .processing_instruction => self.string(self.misc.items[report.index].second.?),
            else => "",
        };
    }

    /// Returns the source location retained for a miscellaneous report.
    pub fn reportLocation(self: *const State, report: Report) ?DeclarationLocation {
        return switch (report.kind) {
            .comment, .processing_instruction => self.misc.items[report.index].location,
            else => null,
        };
    }

    pub fn findGeneralEntity(
        self: *State,
        limits: Limits,
        name: []const u8,
    ) ParseError!?usize {
        const name_hash = std.hash.Wyhash.hash(0, name);
        for (self.entities.items, 0..) |entity, index| {
            if (entity.parameter) continue;
            if (entity.name_hash != name_hash) continue;
            try self.chargeComparison(limits, name.len +| entity.name.len +| 1, 0);
            if (std.mem.eql(u8, name, self.string(entity.name))) return index;
        }
        return null;
    }

    pub fn findAttribute(
        self: *State,
        limits: Limits,
        element_name: []const u8,
        attribute_name: []const u8,
    ) ParseError!?usize {
        for (self.attributes.items, 0..) |attribute, index| {
            try self.chargeComparison(
                limits,
                element_name.len +| attribute.element_name.len +|
                    attribute_name.len +| attribute.name.len +| 2,
                0,
            );
            if (std.mem.eql(u8, element_name, self.string(attribute.element_name)) and
                std.mem.eql(u8, attribute_name, self.string(attribute.name)))
            {
                return index;
            }
        }
        return null;
    }

    pub fn chargeEntity(
        self: *State,
        limits: Limits,
        reference_bytes: usize,
        expanded_bytes: usize,
        offset: usize,
    ) ParseError!void {
        if (self.entity_references == limits.max_entity_references) {
            return self.setLimit(.entity_reference_limit, offset);
        }
        if (reference_bytes > std.math.maxInt(usize) - self.entity_reference_bytes or
            expanded_bytes > limits.max_expanded_bytes -| self.expanded_bytes)
        {
            return self.setLimit(.expanded_bytes_limit, offset);
        }
        const next_reference_bytes = self.entity_reference_bytes + reference_bytes;
        const next_expanded_bytes = self.expanded_bytes + expanded_bytes;
        if (next_expanded_bytes > limits.expansion_ratio_minimum_bytes) {
            const ratio_bytes = std.math.mul(
                usize,
                next_reference_bytes,
                limits.max_expansion_ratio,
            ) catch std.math.maxInt(usize);
            if (next_expanded_bytes > ratio_bytes) {
                return self.setLimit(.expansion_ratio_limit, offset);
            }
        }
        self.entity_references += 1;
        self.entity_reference_bytes = next_reference_bytes;
        self.expanded_bytes = next_expanded_bytes;
    }

    /// Charges semantic bytes produced after an external entity reference has
    /// already been counted. Streaming sources call this once per decoded run.
    pub fn chargeExpanded(
        self: *State,
        limits: Limits,
        expanded_bytes: usize,
        offset: usize,
    ) ParseError!void {
        if (expanded_bytes > limits.max_expanded_bytes -| self.expanded_bytes) {
            return self.setLimit(.expanded_bytes_limit, offset);
        }
        const next_expanded_bytes = self.expanded_bytes + expanded_bytes;
        if (next_expanded_bytes > limits.expansion_ratio_minimum_bytes) {
            const ratio_bytes = std.math.mul(
                usize,
                self.entity_reference_bytes,
                limits.max_expansion_ratio,
            ) catch std.math.maxInt(usize);
            if (next_expanded_bytes > ratio_bytes) {
                return self.setLimit(.expansion_ratio_limit, offset);
            }
        }
        self.expanded_bytes = next_expanded_bytes;
    }

    pub fn equalStored(
        self: *State,
        limits: Limits,
        stored: StoredString,
        bytes: []const u8,
    ) ParseError!bool {
        try self.chargeComparison(limits, stored.len +| bytes.len +| 1, 0);
        return std.mem.eql(u8, self.string(stored), bytes);
    }

    pub fn appendDoctypeByte(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        byte: u8,
    ) ParseError!void {
        if (self.doctype_bytes.items.len == limits.max_dtd_bytes) {
            return self.setLimit(.dtd_bytes_limit, self.doctype_bytes.items.len);
        }
        self.doctype_bytes.append(allocator, byte) catch return error.OutOfMemory;
    }

    pub fn parseDoctype(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) ParseError!void {
        self.failure = null;
        var parser = Parser{
            .allocator = allocator,
            .limits = limits,
            .state = self,
            .subset = self.doctype_bytes.items,
        };
        defer parser.sources.deinit(allocator);
        try parser.parseDoctype();
    }

    /// Parses the document type while leaving its external subset unattached.
    pub fn parseDoctypeInternalOnly(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) ParseError!void {
        self.failure = null;
        var parser = Parser{
            .allocator = allocator,
            .limits = limits,
            .state = self,
            .subset = self.doctype_bytes.items,
            .omit_external_subset = true,
        };
        defer parser.sources.deinit(allocator);
        try parser.parseDoctype();
    }

    /// Parses a document type and obtains external declaration sources through `provider`.
    pub fn parseDoctypeExternal(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        provider: ExternalProvider,
    ) ParseError!void {
        self.failure = null;
        var parser = Parser{
            .allocator = allocator,
            .limits = limits,
            .state = self,
            .subset = self.doctype_bytes.items,
            .external_provider = provider,
        };
        defer parser.sources.deinit(allocator);
        try parser.parseDoctype();
    }

    /// Parses one decoded UTF-8 external subset without a document type wrapper.
    pub fn parseExternalSubset(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        bytes: []const u8,
        base_id: ?[]const u8,
        source_id: u32,
        provider: ?ExternalProvider,
    ) ParseError!void {
        self.failure = null;
        var parser = Parser{
            .allocator = allocator,
            .limits = limits,
            .state = self,
            .subset = &.{},
            .external_provider = provider,
        };
        defer parser.sources.deinit(allocator);
        try parser.sources.append(allocator, .{
            .storage = .borrowed,
            .offset = 0,
            .len = bytes.len,
            .bytes = bytes,
            .base_id = base_id,
            .source_id = source_id,
            .external = true,
        });
        try parser.parseSubset();
    }

    pub const AppendExternalResult = struct {
        byte_base: usize,
        grammar_unchanged: bool,
    };

    /// Appends pre-parsed external declarations after per-document declarations.
    pub fn appendExternalDeclarations(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        external: *const State,
    ) ParseError!AppendExternalResult {
        const grammar_unchanged = self.elements.items.len == 0 and
            self.attributes.items.len == 0 and self.entities.items.len == 0 and
            self.notations.items.len == 0 and self.nesting_violations.items.len == 0;

        if (external.declaration_count > limits.max_declarations -| self.declaration_count) {
            return self.setLimit(.declaration_limit, 0);
        }
        if (external.declaration_bytes > limits.max_declaration_bytes -| self.declaration_bytes) {
            return self.setLimit(.declaration_bytes_limit, 0);
        }
        if (external.grammar_nodes > limits.max_grammar_nodes -| self.grammar_nodes) {
            return self.setLimit(.grammar_node_limit, 0);
        }
        if (external.replacement_bytes > limits.max_entity_replacement_bytes -| self.replacement_bytes) {
            return self.setLimit(.replacement_bytes_limit, 0);
        }
        if (external.elements.items.len > limits.max_element_declarations -| self.elements.items.len) {
            return self.setLimit(.element_declaration_limit, 0);
        }
        if (external.notations.items.len > limits.max_notation_declarations -| self.notations.items.len) {
            return self.setLimit(.notation_declaration_limit, 0);
        }

        var attribute_additions: usize = 0;
        for (external.attributes.items) |attribute| {
            if (!try self.hasAttributeDeclaration(
                limits,
                external.string(attribute.element_name),
                external.string(attribute.name),
            )) attribute_additions += 1;
        }
        if (attribute_additions > limits.max_attribute_declarations -| self.attributes.items.len) {
            return self.setLimit(.attribute_declaration_limit, 0);
        }

        var entity_additions: usize = 0;
        for (external.entities.items) |entity| {
            if (!try self.hasEntityDeclaration(
                limits,
                external.string(entity.name),
                entity.parameter,
            )) entity_additions += 1;
        }
        if (entity_additions > limits.max_entity_declarations -| self.entities.items.len) {
            return self.setLimit(.entity_declaration_limit, 0);
        }

        const missing = std.math.maxInt(usize);
        const element_map = try allocator.alloc(usize, external.elements.items.len);
        defer allocator.free(element_map);
        const entity_map = try allocator.alloc(usize, external.entities.items.len);
        defer allocator.free(entity_map);
        const notation_map = try allocator.alloc(usize, external.notations.items.len);
        defer allocator.free(notation_map);
        const misc_map = try allocator.alloc(usize, external.misc.items.len);
        defer allocator.free(misc_map);
        const skipped_map = try allocator.alloc(usize, external.skipped_external.items.len);
        defer allocator.free(skipped_map);
        @memset(entity_map, missing);

        const byte_base = self.bytes.items.len;
        try self.bytes.appendSlice(allocator, external.bytes.items);

        for (external.elements.items, 0..) |element, index| {
            element_map[index] = self.elements.items.len;
            try self.elements.append(allocator, .{
                .name = shifted(element.name, byte_base),
                .content_kind = element.content_kind,
                .content_spec = shiftedOptional(element.content_spec, byte_base),
                .location = element.location,
                .declared_external = true,
            });
        }
        for (external.attributes.items) |attribute| {
            if (try self.hasAttributeDeclaration(
                limits,
                external.string(attribute.element_name),
                external.string(attribute.name),
            )) continue;
            try self.attributes.append(allocator, .{
                .element_name = shifted(attribute.element_name, byte_base),
                .name = shifted(attribute.name, byte_base),
                .attribute_type = attribute.attribute_type,
                .default_kind = attribute.default_kind,
                .default_value = shiftedOptional(attribute.default_value, byte_base),
                .allowed_values = shiftedOptional(attribute.allowed_values, byte_base),
                .order = self.attributes.items.len,
                .location = attribute.location,
                .declared_external = true,
            });
        }
        for (external.entities.items, 0..) |entity, index| {
            if (try self.hasEntityDeclaration(
                limits,
                external.string(entity.name),
                entity.parameter,
            )) continue;
            entity_map[index] = self.entities.items.len;
            try self.entities.append(allocator, .{
                .name = shifted(entity.name, byte_base),
                .name_hash = entity.name_hash,
                .value = shiftedOptional(entity.value, byte_base),
                .external_id = shiftedExternalId(entity.external_id, byte_base),
                .parameter = entity.parameter,
                .unparsed = entity.unparsed,
                .notation_name = shiftedOptional(entity.notation_name, byte_base),
                .base_id = shiftedOptional(entity.base_id, byte_base),
                .declared_external = true,
                .location = entity.location,
            });
        }
        for (external.notations.items, 0..) |notation, index| {
            notation_map[index] = self.notations.items.len;
            try self.notations.append(allocator, .{
                .name = shifted(notation.name, byte_base),
                .external_id = shiftedExternalId(notation.external_id, byte_base),
                .location = notation.location,
            });
        }
        for (external.misc.items, 0..) |misc, index| {
            misc_map[index] = self.misc.items.len;
            try self.misc.append(allocator, .{
                .first = shifted(misc.first, byte_base),
                .second = shiftedOptional(misc.second, byte_base),
                .location = misc.location,
            });
        }
        for (external.skipped_external.items, 0..) |skipped, index| {
            skipped_map[index] = self.skipped_external.items.len;
            try self.skipped_external.append(allocator, .{
                .kind = skipped.kind,
                .name = shiftedOptional(skipped.name, byte_base),
                .public_id = shiftedOptional(skipped.public_id, byte_base),
                .system_id = shifted(skipped.system_id, byte_base),
                .offset = skipped.offset,
            });
        }
        for (external.nesting_violations.items) |location| {
            try self.nesting_violations.append(allocator, location);
        }
        for (external.reports.items) |report| {
            const mapped: ?Report = switch (report.kind) {
                .element => .{ .kind = .element, .index = element_map[report.index] },
                .attribute_list => .{
                    .kind = .attribute_list,
                    .index = 0,
                    .name = shiftedOptional(report.name, byte_base),
                },
                .parsed_entity, .unparsed_entity => if (entity_map[report.index] == missing)
                    null
                else
                    .{ .kind = report.kind, .index = entity_map[report.index] },
                .notation => .{ .kind = .notation, .index = notation_map[report.index] },
                .comment, .processing_instruction => .{
                    .kind = report.kind,
                    .index = misc_map[report.index],
                },
                .skipped_external => .{
                    .kind = .skipped_external,
                    .index = skipped_map[report.index],
                },
            };
            if (mapped) |value| try self.reports.append(allocator, value);
        }

        self.declaration_count += external.declaration_count;
        self.declaration_bytes += external.declaration_bytes;
        self.grammar_nodes += external.grammar_nodes;
        self.replacement_bytes += external.replacement_bytes;
        self.parameter_reference_seen = self.parameter_reference_seen or external.parameter_reference_seen;
        return .{ .byte_base = byte_base, .grammar_unchanged = grammar_unchanged };
    }

    fn hasAttributeDeclaration(
        self: *State,
        limits: Limits,
        element_name: []const u8,
        name: []const u8,
    ) ParseError!bool {
        for (self.attributes.items) |attribute| {
            try self.chargeComparison(
                limits,
                element_name.len +| attribute.element_name.len +| name.len +| attribute.name.len +| 2,
                0,
            );
            if (std.mem.eql(u8, element_name, self.string(attribute.element_name)) and
                std.mem.eql(u8, name, self.string(attribute.name))) return true;
        }
        return false;
    }

    fn hasEntityDeclaration(
        self: *State,
        limits: Limits,
        name: []const u8,
        parameter: bool,
    ) ParseError!bool {
        for (self.entities.items) |entity| {
            if (entity.parameter != parameter) continue;
            try self.chargeComparison(limits, name.len +| entity.name.len +| 1, 0);
            if (std.mem.eql(u8, name, self.string(entity.name))) return true;
        }
        return false;
    }

    fn store(self: *State, allocator: std.mem.Allocator, value: []const u8) ParseError!StoredString {
        const offset = self.bytes.items.len;
        self.bytes.appendSlice(allocator, value) catch return error.OutOfMemory;
        return .{ .offset = offset, .len = value.len };
    }

    fn chargeComparison(
        self: *State,
        limits: Limits,
        amount: usize,
        offset: usize,
    ) ParseError!void {
        if (amount > limits.max_comparison_work -| self.comparison_work) {
            return self.setLimit(.comparison_work_limit, offset);
        }
        self.comparison_work += amount;
    }

    fn setInvalid(self: *State, code: ErrorCode, offset: usize) ParseError {
        self.failure = .{ .code = code, .offset = offset };
        return error.InvalidDtd;
    }

    fn setUnsupported(self: *State, code: ErrorCode, offset: usize) ParseError {
        self.failure = .{ .code = code, .offset = offset };
        return error.UnsupportedFeature;
    }

    fn setLimit(self: *State, code: ErrorCode, offset: usize) ParseError {
        self.failure = .{ .code = code, .offset = offset };
        return error.LimitExceeded;
    }
};

fn shifted(value: StoredString, base: usize) StoredString {
    return .{ .offset = base + value.offset, .len = value.len };
}

fn shiftedOptional(value: ?StoredString, base: usize) ?StoredString {
    return if (value) |stored| shifted(stored, base) else null;
}

fn shiftedExternalId(value: ExternalId, base: usize) ExternalId {
    return .{
        .public_id = shiftedOptional(value.public_id, base),
        .system_id = shiftedOptional(value.system_id, base),
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    state: *State,
    subset: []const u8,
    sources: std.ArrayList(Source) = .empty,
    external_provider: ?ExternalProvider = null,
    omit_external_subset: bool = false,
    diagnostic_source_id: u32 = 0,
    conditional_header_byte_entity: ?usize = null,

    fn parseDoctype(self: *Parser) ParseError!void {
        var cursor: usize = 0;
        if (!requireWhitespace(self.subset, &cursor)) {
            return self.invalid(.malformed_doctype, cursor);
        }
        const root = scanName(self.subset, &cursor) orelse
            return self.invalid(.malformed_doctype, cursor);
        self.state.root_name = try self.state.store(self.allocator, root);
        skipWhitespace(self.subset, &cursor);
        if (startsKeyword(self.subset, cursor, "SYSTEM") or
            startsKeyword(self.subset, cursor, "PUBLIC"))
        {
            self.state.external_id = try self.parseExternalId(
                null,
                self.subset,
                &cursor,
                true,
                .malformed_doctype,
            );
            skipWhitespace(self.subset, &cursor);
        }
        var internal_source: ?Source = null;
        if (cursor < self.subset.len and self.subset[cursor] == '[') {
            cursor += 1;
            const subset_start = cursor;
            const subset_end = findSubsetEnd(self.subset, subset_start) orelse
                return self.invalid(.malformed_doctype, cursor);
            cursor = subset_end + 1;
            skipWhitespace(self.subset, &cursor);
            if (cursor >= self.subset.len or self.subset[cursor] != '>') {
                return self.invalid(.malformed_doctype, cursor);
            }
            cursor += 1;
            skipWhitespace(self.subset, &cursor);
            if (cursor != self.subset.len) return self.invalid(.malformed_doctype, cursor);
            internal_source = .{
                .storage = .subset,
                .offset = subset_start,
                .len = subset_end - subset_start,
            };
        } else {
            if (cursor >= self.subset.len or self.subset[cursor] != '>') {
                return self.invalid(.malformed_doctype, cursor);
            }
            cursor += 1;
            skipWhitespace(self.subset, &cursor);
            if (cursor != self.subset.len) return self.invalid(.malformed_doctype, cursor);
        }
        if (self.state.external_id.system_id) |system_id| {
            if (self.omit_external_subset) {
                if (internal_source) |source| try self.sources.append(self.allocator, source);
                if (self.sources.items.len != 0) try self.parseSubset();
                return;
            }
            const provider = self.external_provider orelse
                return self.state.setUnsupported(.external_subset_unsupported, 0);
            const result = try provider.resolve(.{
                .kind = .subset,
                .public_id = if (self.state.external_id.public_id) |value|
                    self.state.string(value)
                else
                    null,
                .system_id = self.state.string(system_id),
                .inclusion_offset = 0,
            });
            switch (result) {
                .content => |content| try self.sources.append(self.allocator, .{
                    .storage = .borrowed,
                    .offset = 0,
                    .len = content.bytes.len,
                    .bytes = content.bytes,
                    .base_id = content.base_id,
                    .source_id = content.source_id,
                    .external = true,
                }),
                .skipped => {
                    const index = self.state.skipped_external.items.len;
                    try self.state.skipped_external.append(self.allocator, .{
                        .kind = .subset,
                        .public_id = self.state.external_id.public_id,
                        .system_id = system_id,
                        .offset = 0,
                    });
                    try self.state.reports.append(self.allocator, .{
                        .kind = .skipped_external,
                        .index = index,
                    });
                },
            }
        } else if (self.state.external_id.public_id != null) {
            return self.invalid(.malformed_doctype, 0);
        }
        // Sources are consumed from the end. The internal subset is processed
        // first so its first declarations take precedence over external ones.
        if (internal_source) |source| try self.sources.append(self.allocator, source);
        if (self.sources.items.len != 0) try self.parseSubset();
    }

    fn parseSubset(self: *Parser) ParseError!void {
        while (try self.ensureSource()) {
            try self.skipLogicalWhitespace();
            if (!try self.ensureSource()) break;
            const offset = self.logicalOffset();
            if (self.peek() == '%') {
                try self.pushParameterReference();
                if (self.sources.items.len != 0) {
                    self.sources.items[self.sources.items.len - 1].boundary_space = true;
                }
                continue;
            }
            if (self.peek() != '<') return self.invalid(.malformed_declaration, offset);
            const source_index = self.sources.items.len - 1;
            const source = self.sourceBytes(source_index);
            var cursor = self.sources.items[source_index].cursor;
            if (std.mem.startsWith(u8, source[cursor..], "<![")) {
                try self.parseConditionalSection(source_index, &cursor);
                self.sources.items[source_index].cursor = cursor;
                continue;
            }
            if (self.sources.items[source_index].external) {
                try self.parseExternalDeclaration();
                continue;
            }
            if (self.state.declaration_count == self.limits.max_declarations) {
                return self.limit(.declaration_limit, offset);
            }
            const declaration_start = cursor;
            try self.chargeDeclarationBytes(
                source,
                declaration_start,
                offset,
            );
            if (std.mem.startsWith(u8, source[cursor..], "<!--")) {
                try self.parseComment(source_index, &cursor);
            } else if (std.mem.startsWith(u8, source[cursor..], "<?")) {
                try self.parseProcessingInstruction(source_index, &cursor);
            } else if (std.mem.startsWith(u8, source[cursor..], "<!ELEMENT")) {
                try self.parseElement(source_index, &cursor);
            } else if (std.mem.startsWith(u8, source[cursor..], "<!ATTLIST")) {
                try self.parseAttributeList(source_index, &cursor);
            } else if (std.mem.startsWith(u8, source[cursor..], "<!ENTITY")) {
                try self.parseEntity(source_index, &cursor);
            } else if (std.mem.startsWith(u8, source[cursor..], "<!NOTATION")) {
                try self.parseNotation(source_index, &cursor);
            } else {
                return self.invalid(.malformed_declaration, offset);
            }
            if (self.sources.items.len - 1 != source_index) unreachable;
            self.sources.items[source_index].cursor = cursor;
            self.state.declaration_count += 1;
        }
    }

    fn parseExternalDeclaration(self: *Parser) ParseError!void {
        if (self.state.declaration_count == self.limits.max_declarations) {
            return self.limit(.declaration_limit, self.logicalOffset());
        }
        const offset = self.logicalOffset();
        const declaration_source = self.sources.items[self.sources.items.len - 1];
        self.diagnostic_source_id = declaration_source.source_id;
        var declaration_base_id = declaration_source.base_id;
        const declaration_entity_index = declaration_source.entity_index;
        const declaration_requires_entity_nesting = declaration_source.boundary_space;
        var logical: std.ArrayList(u8) = .empty;
        defer logical.deinit(self.allocator);
        var group_entities: std.ArrayList(?usize) = .empty;
        defer group_entities.deinit(self.allocator);
        var nesting_recorded = false;
        var quote: u8 = 0;
        var quote_entity_index: ?usize = null;
        var comment = false;
        var processing_instruction = false;
        while (self.sources.items.len != 0) {
            while (self.sources.items.len != 0) {
                const top = self.sources.items[self.sources.items.len - 1];
                if (top.cursor < top.len) break;
                _ = self.sources.pop();
                if (top.boundary_space) {
                    logical.append(self.allocator, ' ') catch return error.OutOfMemory;
                }
            }
            if (self.sources.items.len == 0) break;
            const index = self.sources.items.len - 1;
            const bytes = self.sourceBytes(index);
            const cursor = self.sources.items[index].cursor;
            if (cursor == bytes.len) continue;
            if (!comment and !processing_instruction and bytes[cursor] == '%' and
                parameterReferenceLength(bytes[cursor..]) != null and
                quote == 0)
            {
                if (quote == 0) logical.append(self.allocator, ' ') catch return error.OutOfMemory;
                try self.pushParameterReference();
                if (self.sources.items[self.sources.items.len - 1].base_id) |base_id| {
                    declaration_base_id = base_id;
                }
                if (quote == 0) self.sources.items[self.sources.items.len - 1].boundary_space = true;
                continue;
            }
            const byte = bytes[cursor];
            self.sources.items[index].cursor += 1;
            logical.append(self.allocator, byte) catch return error.OutOfMemory;
            if (logical.items.len > self.limits.max_declaration_bytes -| self.state.declaration_bytes) {
                return self.limit(.declaration_bytes_limit, offset);
            }
            if (quote != 0) {
                if (byte == quote and self.sources.items[index].entity_index == quote_entity_index) {
                    quote = 0;
                    quote_entity_index = null;
                }
                continue;
            }
            if (comment) {
                if (std.mem.endsWith(u8, logical.items, "-->")) {
                    if (declaration_requires_entity_nesting and
                        self.sources.items[index].entity_index != declaration_entity_index)
                    {
                        return self.invalid(.malformed_declaration, offset);
                    }
                    break;
                }
                continue;
            }
            if (processing_instruction) {
                if (std.mem.endsWith(u8, logical.items, "?>")) {
                    if (declaration_requires_entity_nesting and
                        self.sources.items[index].entity_index != declaration_entity_index)
                    {
                        return self.invalid(.malformed_declaration, offset);
                    }
                    break;
                }
                continue;
            }
            if (std.mem.endsWith(u8, logical.items, "<!--")) {
                comment = true;
            } else if (logical.items.len == 2 and std.mem.eql(u8, logical.items, "<?")) {
                processing_instruction = true;
            } else if (byte == '\'' or byte == '"') {
                quote = byte;
                quote_entity_index = self.sources.items[index].entity_index;
            } else if (byte == '(') {
                try group_entities.append(self.allocator, self.sources.items[index].entity_index);
            } else if (byte == ')') {
                if (group_entities.pop()) |opening_entity| {
                    if (opening_entity != self.sources.items[index].entity_index and !nesting_recorded) {
                        try self.state.nesting_violations.append(self.allocator, .{
                            .source_id = declaration_source.source_id,
                            .offset = offset,
                        });
                        nesting_recorded = true;
                    }
                }
            } else if (byte == '>') {
                if (self.sources.items[index].entity_index != declaration_entity_index and
                    !nesting_recorded)
                {
                    try self.state.nesting_violations.append(self.allocator, .{
                        .source_id = declaration_source.source_id,
                        .offset = offset,
                    });
                    nesting_recorded = true;
                }
                if (declaration_requires_entity_nesting and
                    self.sources.items[index].entity_index != declaration_entity_index)
                {
                    return self.invalid(.malformed_declaration, offset);
                }
                break;
            }
        }
        if (logical.items.len == 0 or logical.items[logical.items.len - 1] != '>') {
            return self.invalid(.malformed_declaration, offset);
        }
        self.state.declaration_bytes += logical.items.len;
        try self.sources.append(self.allocator, .{
            .storage = .borrowed,
            .offset = 0,
            .len = logical.items.len,
            .bytes = logical.items,
            .base_id = declaration_base_id,
            .source_id = declaration_source.source_id,
            .external = true,
            .reference_offset = offset,
        });
        const logical_index = self.sources.items.len - 1;
        var cursor: usize = 0;
        if (std.mem.startsWith(u8, logical.items, "<!--")) {
            try self.parseComment(logical_index, &cursor);
        } else if (std.mem.startsWith(u8, logical.items, "<?")) {
            try self.parseProcessingInstruction(logical_index, &cursor);
        } else if (std.mem.startsWith(u8, logical.items, "<!ELEMENT")) {
            try self.parseElement(logical_index, &cursor);
        } else if (std.mem.startsWith(u8, logical.items, "<!ATTLIST")) {
            try self.parseAttributeList(logical_index, &cursor);
        } else if (std.mem.startsWith(u8, logical.items, "<!ENTITY")) {
            try self.parseEntity(logical_index, &cursor);
        } else if (std.mem.startsWith(u8, logical.items, "<!NOTATION")) {
            try self.parseNotation(logical_index, &cursor);
        } else {
            return self.invalid(.malformed_declaration, offset);
        }
        if (cursor != logical.items.len) return self.invalid(.malformed_declaration, offset + cursor);
        _ = self.sources.pop();
        self.state.declaration_count += 1;
    }

    fn parameterReferenceLength(bytes: []const u8) ?usize {
        if (bytes.len < 3 or bytes[0] != '%') return null;
        var cursor: usize = 1;
        _ = scanName(bytes, &cursor) orelse return null;
        if (cursor >= bytes.len or bytes[cursor] != ';') return null;
        return cursor + 1;
    }

    fn parseConditionalSection(self: *Parser, source_index: usize, cursor: *usize) ParseError!void {
        if (!self.sources.items[source_index].external) {
            return self.invalid(.malformed_declaration, self.sourceOffset(source_index, cursor.*));
        }
        const start = cursor.*;
        const section_entity = self.sources.items[source_index].entity_index;
        var improper_header_nesting = false;
        self.sources.items[source_index].cursor = cursor.* + 3;
        var keyword: [7]u8 = undefined;
        var keyword_len: usize = 0;
        var bracket_seen = false;
        while (true) {
            const byte = (try self.nextConditionalHeaderByte()) orelse
                return self.invalid(.malformed_declaration, self.logicalOffset());
            if (isWhitespace(byte)) {
                if (keyword_len == 0) continue;
                break;
            }
            if (byte == '[') {
                improper_header_nesting = self.conditional_header_byte_entity != section_entity;
                bracket_seen = true;
                break;
            }
            if (keyword_len == keyword.len) return self.invalid(.malformed_declaration, self.logicalOffset());
            keyword[keyword_len] = byte;
            keyword_len += 1;
        }
        if (!bracket_seen) {
            var byte: u8 = undefined;
            while (true) {
                byte = (try self.nextConditionalHeaderByte()) orelse
                    return self.invalid(.malformed_declaration, self.logicalOffset());
                if (!isWhitespace(byte)) break;
            }
            if (byte != '[') return self.invalid(.malformed_declaration, self.logicalOffset());
            improper_header_nesting = self.conditional_header_byte_entity != section_entity;
        }
        const include = if (std.mem.eql(u8, keyword[0..keyword_len], "INCLUDE"))
            true
        else if (std.mem.eql(u8, keyword[0..keyword_len], "IGNORE"))
            false
        else
            return self.invalid(.malformed_declaration, self.logicalOffset());
        if (improper_header_nesting) {
            try self.state.nesting_violations.append(self.allocator, .{
                .source_id = self.sources.items[source_index].source_id,
                .offset = self.sourceOffset(source_index, start),
            });
        }
        if (!try self.ensureSource()) return self.invalid(.malformed_declaration, start);
        const content_source_index = self.sources.items.len - 1;
        const source = self.sourceBytes(content_source_index);
        const content_start = self.sources.items[content_source_index].cursor;
        var scan = content_start;
        var depth: usize = 1;
        while (scan < source.len) {
            if (std.mem.startsWith(u8, source[scan..], "<![")) {
                depth += 1;
                scan += 3;
            } else if (std.mem.startsWith(u8, source[scan..], "]]>")) {
                depth -= 1;
                if (depth == 0) break;
                scan += 3;
            } else {
                scan += 1;
            }
        }
        if (depth != 0) {
            return self.invalid(.malformed_declaration, self.sourceOffset(source_index, start));
        }
        self.sources.items[content_source_index].cursor = scan + 3;
        if (source_index < self.sources.items.len) cursor.* = self.sources.items[source_index].cursor;
        if (include) {
            const parent = self.sources.items[content_source_index];
            try self.sources.append(self.allocator, .{
                .storage = parent.storage,
                .offset = parent.offset + content_start,
                .len = scan - content_start,
                .bytes = parent.bytes,
                .base_id = parent.base_id,
                .external = true,
            });
        }
    }

    fn nextConditionalHeaderByte(self: *Parser) ParseError!?u8 {
        while (try self.ensureSource()) {
            const index = self.sources.items.len - 1;
            const source = self.sourceBytes(index);
            const cursor = self.sources.items[index].cursor;
            if (source[cursor] == '%' and parameterReferenceLength(source[cursor..]) != null) {
                try self.pushParameterReference();
                continue;
            }
            self.conditional_header_byte_entity = self.sources.items[index].entity_index;
            self.sources.items[index].cursor += 1;
            return source[cursor];
        }
        return null;
    }

    fn parseComment(self: *Parser, source_index: usize, cursor: *usize) ParseError!void {
        const source = self.sourceBytes(source_index);
        const start = cursor.*;
        const close = std.mem.indexOfPos(u8, source, start + 4, "-->") orelse
            return self.invalid(.malformed_comment, self.sourceOffset(source_index, start));
        if (std.mem.indexOf(u8, source[start + 4 .. close], "--") != null) {
            return self.invalid(.malformed_comment, self.sourceOffset(source_index, start));
        }
        const value = try self.state.store(self.allocator, source[start + 4 .. close]);
        const index = self.state.misc.items.len;
        try self.state.misc.append(self.allocator, .{
            .first = value,
            .location = self.declarationLocation(
                source_index,
                self.sourceOffset(source_index, start + 4),
            ),
        });
        try self.state.reports.append(self.allocator, .{ .kind = .comment, .index = index });
        cursor.* = close + 3;
    }

    fn parseProcessingInstruction(
        self: *Parser,
        source_index: usize,
        cursor: *usize,
    ) ParseError!void {
        const source = self.sourceBytes(source_index);
        const start = cursor.*;
        cursor.* += 2;
        const target = scanName(source, cursor) orelse
            return self.invalid(.malformed_processing_instruction, self.sourceOffset(source_index, start));
        if (asciiEqualIgnoreCase(target, "xml")) {
            return self.invalid(.malformed_processing_instruction, self.sourceOffset(source_index, start));
        }
        const data_start = cursor.*;
        if (cursor.* < source.len and !isWhitespace(source[cursor.*]) and
            !std.mem.startsWith(u8, source[cursor.*..], "?>"))
        {
            return self.invalid(.malformed_processing_instruction, self.sourceOffset(source_index, cursor.*));
        }
        const close = std.mem.indexOfPos(u8, source, cursor.*, "?>") orelse
            return self.invalid(.malformed_processing_instruction, self.sourceOffset(source_index, start));
        var normalized_start = data_start;
        while (normalized_start < close and isWhitespace(source[normalized_start])) {
            normalized_start += 1;
        }
        const stored_target = try self.state.store(self.allocator, target);
        const stored_data = try self.state.store(self.allocator, source[normalized_start..close]);
        const index = self.state.misc.items.len;
        try self.state.misc.append(self.allocator, .{
            .first = stored_target,
            .second = stored_data,
            .location = self.declarationLocation(
                source_index,
                self.sourceOffset(source_index, start + 2),
            ),
        });
        try self.state.reports.append(self.allocator, .{
            .kind = .processing_instruction,
            .index = index,
        });
        cursor.* = close + 2;
    }

    fn parseElement(self: *Parser, source_index: usize, cursor: *usize) ParseError!void {
        if (self.state.elements.items.len == self.limits.max_element_declarations) {
            return self.limit(.element_declaration_limit, self.sourceOffset(source_index, cursor.*));
        }
        const source = self.sourceBytes(source_index);
        const declaration_offset = self.sourceOffset(source_index, cursor.*);
        cursor.* += "<!ELEMENT".len;
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
        }
        const name = scanName(source, cursor) orelse
            return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
        }
        const content_start = cursor.*;
        var content_kind: ContentKind = undefined;
        if (startsKeyword(source, cursor.*, "EMPTY")) {
            cursor.* += "EMPTY".len;
            content_kind = .empty;
        } else if (startsKeyword(source, cursor.*, "ANY")) {
            cursor.* += "ANY".len;
            content_kind = .any;
        } else {
            try self.parseContentSpec(source_index, source, cursor);
            content_kind = if (std.mem.indexOf(u8, source[content_start..cursor.*], "#PCDATA") != null)
                .mixed
            else
                .children;
        }
        const content_end = cursor.*;
        skipWhitespace(source, cursor);
        if (cursor.* >= source.len or source[cursor.*] != '>') {
            return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
        }
        cursor.* += 1;
        const stored_name = try self.state.store(self.allocator, name);
        const stored_content = if (content_kind == .mixed or content_kind == .children)
            try self.state.store(self.allocator, source[content_start..content_end])
        else
            null;
        const index = self.state.elements.items.len;
        try self.state.elements.append(self.allocator, .{
            .name = stored_name,
            .content_kind = content_kind,
            .content_spec = stored_content,
            .location = self.declarationLocation(source_index, declaration_offset),
            .declared_external = self.sources.items[source_index].external,
        });
        try self.state.reports.append(self.allocator, .{ .kind = .element, .index = index });
    }

    fn parseContentSpec(
        self: *Parser,
        source_index: usize,
        source: []const u8,
        cursor: *usize,
    ) ParseError!void {
        const Group = struct {
            separator: u8 = 0,
            terms: usize = 0,
            mixed: bool = false,
        };
        var groups: std.ArrayList(Group) = .empty;
        defer groups.deinit(self.allocator);
        if (cursor.* >= source.len or source[cursor.*] != '(') {
            return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
        }
        try groups.append(self.allocator, .{});
        cursor.* += 1;
        var expect_term = true;
        while (cursor.* < source.len) {
            skipWhitespace(source, cursor);
            if (cursor.* >= source.len) break;
            const group = &groups.items[groups.items.len - 1];
            if (expect_term) {
                if (source[cursor.*] == '(') {
                    if (group.mixed) return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
                    if (groups.items.len == self.limits.max_group_depth) {
                        return self.limit(.grammar_depth_limit, self.sourceOffset(source_index, cursor.*));
                    }
                    try groups.append(self.allocator, .{});
                    cursor.* += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, source[cursor.*..], "#PCDATA")) {
                    if (groups.items.len != 1 or group.terms != 0) {
                        return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
                    }
                    cursor.* += "#PCDATA".len;
                    group.mixed = true;
                    group.terms = 1;
                } else if (scanName(source, cursor) != null) {
                    group.terms += 1;
                    if (!group.mixed and cursor.* < source.len and
                        (source[cursor.*] == '?' or source[cursor.*] == '*' or source[cursor.*] == '+'))
                    {
                        cursor.* += 1;
                    }
                } else {
                    return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
                }
                try self.chargeGrammarNode(self.sourceOffset(source_index, cursor.*));
                expect_term = false;
                continue;
            }
            const byte = source[cursor.*];
            if (byte == ',' or byte == '|') {
                const kind: u8 = if (byte == ',') 1 else 2;
                if (group.mixed and kind != 2) {
                    return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
                }
                if (group.separator != 0 and group.separator != kind) {
                    return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
                }
                group.separator = kind;
                cursor.* += 1;
                expect_term = true;
                continue;
            }
            if (byte != ')' or group.terms == 0) {
                return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
            }
            const closed = group.*;
            _ = groups.pop();
            cursor.* += 1;
            if (closed.mixed) {
                if (closed.terms > 1) {
                    if (cursor.* >= source.len or source[cursor.*] != '*') {
                        return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
                    }
                    cursor.* += 1;
                } else if (cursor.* < source.len and source[cursor.*] == '*') {
                    cursor.* += 1;
                } else if (cursor.* < source.len and
                    (source[cursor.*] == '?' or source[cursor.*] == '+'))
                {
                    return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
                }
            } else if (cursor.* < source.len and
                (source[cursor.*] == '?' or source[cursor.*] == '*' or source[cursor.*] == '+'))
            {
                cursor.* += 1;
            }
            if (groups.items.len == 0) return;
            groups.items[groups.items.len - 1].terms += 1;
            try self.chargeGrammarNode(self.sourceOffset(source_index, cursor.*));
            expect_term = false;
        }
        return self.invalid(.malformed_element_declaration, self.sourceOffset(source_index, cursor.*));
    }

    fn parseAttributeList(self: *Parser, source_index: usize, cursor: *usize) ParseError!void {
        const source = self.sourceBytes(source_index);
        cursor.* += "<!ATTLIST".len;
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
        }
        const element_name = scanName(source, cursor) orelse
            return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
        const stored_element_name = try self.state.store(self.allocator, element_name);
        while (true) {
            skipWhitespace(source, cursor);
            if (cursor.* >= source.len) {
                return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            }
            if (source[cursor.*] == '>') {
                cursor.* += 1;
                try self.state.reports.append(self.allocator, .{
                    .kind = .attribute_list,
                    .index = self.state.attributes.items.len,
                    .name = stored_element_name,
                });
                return;
            }
            const declaration_offset = self.sourceOffset(source_index, cursor.*);
            const bytes_checkpoint = self.state.bytes.items.len;
            const replacement_checkpoint = self.state.replacement_bytes;
            const name = scanName(source, cursor) orelse
                return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            var duplicate: ?bool = null;
            if (self.state.attributes.items.len == self.limits.max_attribute_declarations) {
                duplicate = try self.attributeExists(element_name, name, declaration_offset);
                if (!duplicate.?) return self.limit(.attribute_declaration_limit, declaration_offset);
            }
            if (!requireWhitespace(source, cursor)) {
                return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            }
            const parsed_type = try self.parseAttributeType(source_index, source, cursor);
            if (!requireWhitespace(source, cursor)) {
                return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            }
            const default = try self.parseDefaultDeclaration(
                source_index,
                source,
                cursor,
                parsed_type.attribute_type,
            );
            if (duplicate orelse try self.attributeExists(element_name, name, declaration_offset)) {
                self.state.bytes.items.len = bytes_checkpoint;
                self.state.replacement_bytes = replacement_checkpoint;
                continue;
            }
            const stored_name = try self.state.store(self.allocator, name);
            try self.state.attributes.append(self.allocator, .{
                .element_name = stored_element_name,
                .name = stored_name,
                .attribute_type = parsed_type.attribute_type,
                .default_kind = default.kind,
                .default_value = default.value,
                .allowed_values = parsed_type.allowed_values,
                .order = self.state.attributes.items.len,
                .location = self.declarationLocation(source_index, declaration_offset),
                .declared_external = self.sources.items[source_index].external,
            });
        }
    }

    const ParsedAttributeType = struct {
        attribute_type: AttributeType,
        allowed_values: ?StoredString = null,
    };

    fn parseAttributeType(
        self: *Parser,
        source_index: usize,
        source: []const u8,
        cursor: *usize,
    ) ParseError!ParsedAttributeType {
        inline for (.{
            .{ "CDATA", AttributeType.cdata },
            .{ "IDREFS", AttributeType.idrefs },
            .{ "IDREF", AttributeType.idref },
            .{ "ID", AttributeType.id },
            .{ "ENTITIES", AttributeType.entities },
            .{ "ENTITY", AttributeType.entity },
            .{ "NMTOKENS", AttributeType.nmtokens },
            .{ "NMTOKEN", AttributeType.nmtoken },
        }) |entry| {
            if (startsKeyword(source, cursor.*, entry[0])) {
                cursor.* += entry[0].len;
                return .{ .attribute_type = entry[1] };
            }
        }
        if (startsKeyword(source, cursor.*, "NOTATION")) {
            cursor.* += "NOTATION".len;
            if (!requireWhitespace(source, cursor)) {
                return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            }
            const values_start = cursor.*;
            try self.parseNameGroup(source_index, source, cursor, true);
            return .{
                .attribute_type = .notation,
                .allowed_values = try self.state.store(
                    self.allocator,
                    source[values_start..cursor.*],
                ),
            };
        }
        if (cursor.* < source.len and source[cursor.*] == '(') {
            const values_start = cursor.*;
            try self.parseNameGroup(source_index, source, cursor, false);
            return .{
                .attribute_type = .enumeration,
                .allowed_values = try self.state.store(
                    self.allocator,
                    source[values_start..cursor.*],
                ),
            };
        }
        return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
    }

    fn parseNameGroup(
        self: *Parser,
        source_index: usize,
        source: []const u8,
        cursor: *usize,
        names: bool,
    ) ParseError!void {
        if (cursor.* >= source.len or source[cursor.*] != '(') {
            return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
        }
        cursor.* += 1;
        while (true) {
            skipWhitespace(source, cursor);
            const item = if (names) scanName(source, cursor) else scanNmtoken(source, cursor);
            if (item == null) return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            try self.chargeGrammarNode(self.sourceOffset(source_index, cursor.*));
            skipWhitespace(source, cursor);
            if (cursor.* >= source.len) return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            if (source[cursor.*] == ')') {
                cursor.* += 1;
                return;
            }
            if (source[cursor.*] != '|') return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            cursor.* += 1;
        }
    }

    const ParsedDefault = struct {
        kind: DefaultKind,
        value: ?StoredString = null,
    };

    fn parseDefaultDeclaration(
        self: *Parser,
        source_index: usize,
        source: []const u8,
        cursor: *usize,
        attribute_type: AttributeType,
    ) ParseError!ParsedDefault {
        if (std.mem.startsWith(u8, source[cursor.*..], "#REQUIRED")) {
            cursor.* += "#REQUIRED".len;
            return .{ .kind = .required };
        }
        if (std.mem.startsWith(u8, source[cursor.*..], "#IMPLIED")) {
            cursor.* += "#IMPLIED".len;
            return .{ .kind = .implied };
        }
        var kind: DefaultKind = .value;
        if (std.mem.startsWith(u8, source[cursor.*..], "#FIXED")) {
            cursor.* += "#FIXED".len;
            if (!requireWhitespace(source, cursor)) {
                return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
            }
            kind = .fixed;
        }
        const raw_start = cursor.* + 1;
        const raw = scanQuoted(source, cursor) orelse
            return self.invalid(.malformed_attribute_list, self.sourceOffset(source_index, cursor.*));
        if (std.mem.indexOfScalar(u8, raw, '<')) |index| {
            return self.invalid(
                .malformed_attribute_list,
                self.sourceOffset(source_index, raw_start + index),
            );
        }
        const normalized = try self.normalizeDeclarationValue(
            source_index,
            raw_start,
            raw,
            attribute_type.isTokenized(),
            false,
            .malformed_attribute_list,
        );
        return .{ .kind = kind, .value = normalized };
    }

    fn parseEntity(self: *Parser, source_index: usize, cursor: *usize) ParseError!void {
        const source = self.sourceBytes(source_index);
        const declaration_offset = self.sourceOffset(source_index, cursor.*);
        cursor.* += "<!ENTITY".len;
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
        }
        var parameter = false;
        if (cursor.* < source.len and source[cursor.*] == '%') {
            parameter = true;
            cursor.* += 1;
            if (!requireWhitespace(source, cursor)) {
                return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
            }
        }
        const name = scanName(source, cursor) orelse
            return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
        }
        var duplicate: ?bool = null;
        if (self.state.entities.items.len == self.limits.max_entity_declarations) {
            duplicate = try self.entityExists(name, parameter, declaration_offset);
            if (!duplicate.?) return self.limit(.entity_declaration_limit, declaration_offset);
        }
        const bytes_checkpoint = self.state.bytes.items.len;
        const replacement_checkpoint = self.state.replacement_bytes;
        var declaration: EntityDeclaration = .{
            .name = undefined,
            .name_hash = std.hash.Wyhash.hash(0, name),
            .value = null,
            .parameter = parameter,
            .declared_external = self.sources.items[source_index].external,
            .location = self.declarationLocation(source_index, declaration_offset),
        };
        if (self.sources.items[source_index].base_id) |base_id| {
            declaration.base_id = try self.state.store(self.allocator, base_id);
        }
        if (cursor.* < source.len and (source[cursor.*] == '\'' or source[cursor.*] == '"')) {
            const raw_start = cursor.* + 1;
            const raw = scanQuoted(source, cursor) orelse unreachable;
            var expanded_parameter_value: std.ArrayList(u8) = .empty;
            defer expanded_parameter_value.deinit(self.allocator);
            const normalized_raw = if (std.mem.indexOfScalar(u8, raw, '%')) |index| value: {
                if (!self.sources.items[source_index].external) {
                    return self.invalid(
                        .malformed_entity_declaration,
                        self.sourceOffset(source_index, raw_start + index),
                    );
                }
                try self.expandParameterValue(
                    &expanded_parameter_value,
                    raw,
                    self.sourceOffset(source_index, raw_start + index),
                );
                break :value expanded_parameter_value.items;
            } else raw;
            declaration.value = try self.normalizeDeclarationValue(
                source_index,
                raw_start,
                normalized_raw,
                false,
                true,
                .malformed_entity_declaration,
            );
            if (!parameter and !self.validPredefinedDeclaration(name, declaration.value.?)) {
                return self.invalid(
                    .malformed_entity_declaration,
                    self.sourceOffset(source_index, cursor.*),
                );
            }
        } else {
            declaration.external_id = try self.parseExternalId(
                source_index,
                source,
                cursor,
                false,
                .malformed_entity_declaration,
            );
            if (!parameter) {
                const before_space = cursor.*;
                skipWhitespace(source, cursor);
                if (startsKeyword(source, cursor.*, "NDATA")) {
                    if (cursor.* == before_space) {
                        return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
                    }
                    cursor.* += "NDATA".len;
                    if (!requireWhitespace(source, cursor)) {
                        return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
                    }
                    const notation = scanName(source, cursor) orelse
                        return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
                    declaration.unparsed = true;
                    declaration.notation_name = try self.state.store(self.allocator, notation);
                }
            }
        }
        skipWhitespace(source, cursor);
        if (cursor.* >= source.len or source[cursor.*] != '>') {
            return self.invalid(.malformed_entity_declaration, self.sourceOffset(source_index, cursor.*));
        }
        cursor.* += 1;
        if (!parameter and predefined(name) != null and declaration.value == null) {
            return self.invalid(
                .malformed_entity_declaration,
                self.sourceOffset(source_index, cursor.*),
            );
        }
        if (duplicate orelse try self.entityExists(name, parameter, declaration_offset)) {
            self.state.bytes.items.len = bytes_checkpoint;
            self.state.replacement_bytes = replacement_checkpoint;
            return;
        }
        declaration.name = try self.state.store(self.allocator, name);
        const index = self.state.entities.items.len;
        try self.state.entities.append(self.allocator, declaration);
        try self.state.reports.append(self.allocator, .{
            .kind = if (declaration.unparsed) .unparsed_entity else .parsed_entity,
            .index = index,
        });
    }

    fn expandParameterValue(
        self: *Parser,
        output: *std.ArrayList(u8),
        initial: []const u8,
        offset: usize,
    ) ParseError!void {
        const Frame = struct {
            bytes: []const u8,
            cursor: usize = 0,
            entity_index: ?usize = null,
        };
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(self.allocator);
        try frames.append(self.allocator, .{ .bytes = initial });
        while (frames.items.len != 0) {
            const frame = &frames.items[frames.items.len - 1];
            if (frame.cursor == frame.bytes.len) {
                _ = frames.pop();
                continue;
            }
            const percent = std.mem.indexOfScalarPos(u8, frame.bytes, frame.cursor, '%') orelse {
                try self.appendParameterValue(output, frame.bytes[frame.cursor..], offset);
                frame.cursor = frame.bytes.len;
                continue;
            };
            try self.appendParameterValue(output, frame.bytes[frame.cursor..percent], offset);
            const length = parameterReferenceLength(frame.bytes[percent..]) orelse
                return self.invalid(.malformed_entity_declaration, offset);
            const name = frame.bytes[percent + 1 .. percent + length - 1];
            frame.cursor = percent + length;
            const entity_index = try self.findParameterEntity(name, offset) orelse
                return self.invalid(.undeclared_parameter_entity, offset);
            for (frames.items) |active| {
                if (active.entity_index == entity_index) {
                    return self.invalid(.recursive_parameter_entity, offset);
                }
            }
            if (frames.items.len == self.limits.max_active_entity_depth) {
                return self.limit(.entity_depth_limit, offset);
            }
            const entity = self.state.entities.items[entity_index];
            var value: []const u8 = undefined;
            if (entity.value) |stored| {
                value = self.state.string(stored);
            } else {
                const provider = self.external_provider orelse
                    return self.state.setUnsupported(.external_subset_unsupported, offset);
                const system_id = entity.external_id.system_id orelse
                    return self.invalid(.malformed_entity_declaration, offset);
                const result = try provider.resolve(.{
                    .kind = .parameter_entity,
                    .name = self.state.string(entity.name),
                    .public_id = if (entity.external_id.public_id) |public|
                        self.state.string(public)
                    else
                        null,
                    .system_id = self.state.string(system_id),
                    .base_id = if (entity.base_id) |base_id| self.state.string(base_id) else null,
                });
                value = switch (result) {
                    .content => |content| content.bytes,
                    .skipped => return,
                };
            }
            try self.state.chargeEntity(self.limits, name.len +| 2, value.len, offset);
            try frames.append(self.allocator, .{ .bytes = value, .entity_index = entity_index });
        }
    }

    fn appendParameterValue(
        self: *Parser,
        output: *std.ArrayList(u8),
        bytes: []const u8,
        offset: usize,
    ) ParseError!void {
        if (bytes.len > self.limits.max_entity_replacement_bytes -| output.items.len) {
            return self.limit(.replacement_bytes_limit, offset);
        }
        output.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }

    fn parseNotation(self: *Parser, source_index: usize, cursor: *usize) ParseError!void {
        if (self.state.notations.items.len == self.limits.max_notation_declarations) {
            return self.limit(.notation_declaration_limit, self.sourceOffset(source_index, cursor.*));
        }
        const source = self.sourceBytes(source_index);
        const declaration_offset = self.sourceOffset(source_index, cursor.*);
        cursor.* += "<!NOTATION".len;
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(.malformed_notation_declaration, self.sourceOffset(source_index, cursor.*));
        }
        const name = scanName(source, cursor) orelse
            return self.invalid(.malformed_notation_declaration, self.sourceOffset(source_index, cursor.*));
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(.malformed_notation_declaration, self.sourceOffset(source_index, cursor.*));
        }
        const external_id = try self.parseExternalId(
            source_index,
            source,
            cursor,
            true,
            .malformed_notation_declaration,
        );
        skipWhitespace(source, cursor);
        if (cursor.* >= source.len or source[cursor.*] != '>') {
            return self.invalid(.malformed_notation_declaration, self.sourceOffset(source_index, cursor.*));
        }
        cursor.* += 1;
        const stored_name = try self.state.store(self.allocator, name);
        const index = self.state.notations.items.len;
        try self.state.notations.append(self.allocator, .{
            .name = stored_name,
            .external_id = external_id,
            .location = self.declarationLocation(source_index, declaration_offset),
        });
        try self.state.reports.append(self.allocator, .{ .kind = .notation, .index = index });
    }

    fn declarationLocation(
        self: *const Parser,
        source_index: usize,
        offset: usize,
    ) DeclarationLocation {
        return .{
            .source_id = self.sources.items[source_index].source_id,
            .offset = offset,
        };
    }

    fn parseExternalId(
        self: *Parser,
        source_index: ?usize,
        source: []const u8,
        cursor: *usize,
        public_only: bool,
        error_code: ErrorCode,
    ) ParseError!ExternalId {
        var result: ExternalId = .{};
        if (startsKeyword(source, cursor.*, "SYSTEM")) {
            cursor.* += "SYSTEM".len;
            if (!requireWhitespace(source, cursor)) {
                return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
            }
            const system = scanQuoted(source, cursor) orelse
                return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
            result.system_id = try self.state.store(self.allocator, system);
            return result;
        }
        if (!startsKeyword(source, cursor.*, "PUBLIC")) {
            return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
        }
        cursor.* += "PUBLIC".len;
        if (!requireWhitespace(source, cursor)) {
            return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
        }
        const public = scanQuoted(source, cursor) orelse
            return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
        if (!validPublicId(public)) {
            return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
        }
        result.public_id = try self.state.store(self.allocator, public);
        const whitespace_start = cursor.*;
        skipWhitespace(source, cursor);
        if (cursor.* < source.len and (source[cursor.*] == '\'' or source[cursor.*] == '"')) {
            if (cursor.* == whitespace_start) {
                return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
            }
            result.system_id = try self.state.store(self.allocator, scanQuoted(source, cursor).?);
        } else if (!public_only) {
            return self.invalid(error_code, self.diagnosticOffset(source_index, cursor.*));
        }
        return result;
    }

    fn normalizeDeclarationValue(
        self: *Parser,
        source_index: usize,
        raw_start: usize,
        raw: []const u8,
        tokenized: bool,
        preserve_general_references: bool,
        error_code: ErrorCode,
    ) ParseError!StoredString {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        var cursor: usize = 0;
        while (cursor < raw.len) {
            const byte = raw[cursor];
            if (byte == '&') {
                const end = std.mem.indexOfScalarPos(u8, raw, cursor + 1, ';') orelse
                    return self.invalid(error_code, self.sourceOffset(source_index, raw_start + cursor));
                const token = raw[cursor + 1 .. end];
                if (token.len > 0 and token[0] == '#') {
                    var encoded: [4]u8 = undefined;
                    const len = decodeCharacterReference(token, &encoded, self.state.version) orelse
                        return self.invalid(error_code, self.sourceOffset(source_index, raw_start + cursor));
                    try self.appendReplacement(
                        &output,
                        encoded[0..len],
                        self.sourceOffset(source_index, raw_start + cursor),
                    );
                } else if (preserve_general_references) {
                    var name_cursor: usize = 0;
                    const parsed_name = scanName(token, &name_cursor);
                    if (parsed_name == null or name_cursor != token.len) {
                        return self.invalid(error_code, self.sourceOffset(source_index, raw_start + cursor));
                    }
                    try self.appendReplacement(
                        &output,
                        raw[cursor .. end + 1],
                        self.sourceOffset(source_index, raw_start + cursor),
                    );
                } else if (predefined(token)) |replacement| {
                    try self.appendReplacement(
                        &output,
                        replacement,
                        self.sourceOffset(source_index, raw_start + cursor),
                    );
                } else {
                    const entity_index = try self.state.findGeneralEntity(self.limits, token) orelse
                        return self.invalid(error_code, self.sourceOffset(source_index, raw_start + cursor));
                    const entity = self.state.entities.items[entity_index];
                    if (entity.value == null or entity.unparsed) {
                        return self.invalid(
                            error_code,
                            self.sourceOffset(source_index, raw_start + cursor),
                        );
                    }
                    try self.expandGeneralValue(
                        &output,
                        entity_index,
                        self.sourceOffset(source_index, raw_start + cursor),
                    );
                }
                cursor = end + 1;
                continue;
            }
            const normalized = if (byte == '\t' or byte == '\n' or byte == '\r') ' ' else byte;
            try self.appendReplacement(
                &output,
                &.{normalized},
                self.sourceOffset(source_index, raw_start + cursor),
            );
            cursor += 1;
        }
        if (tokenized) output.items.len = collapseSpaces(output.items);
        self.state.replacement_bytes += output.items.len;
        return self.state.store(self.allocator, output.items);
    }

    fn validPredefinedDeclaration(
        self: *Parser,
        name: []const u8,
        value: StoredString,
    ) bool {
        const replacement = self.state.string(value);
        if (std.mem.eql(u8, name, "lt")) {
            return characterReferenceEquals(replacement, '<', self.state.version);
        }
        if (std.mem.eql(u8, name, "amp")) {
            return characterReferenceEquals(replacement, '&', self.state.version);
        }
        const expected: ?u21 = if (std.mem.eql(u8, name, "gt"))
            '>'
        else if (std.mem.eql(u8, name, "apos"))
            '\''
        else if (std.mem.eql(u8, name, "quot"))
            '"'
        else
            null;
        const scalar = expected orelse return true;
        return (replacement.len == 1 and replacement[0] == scalar) or
            characterReferenceEquals(replacement, scalar, self.state.version);
    }

    fn expandGeneralValue(
        self: *Parser,
        output: *std.ArrayList(u8),
        initial_index: usize,
        offset: usize,
    ) ParseError!void {
        const Frame = struct {
            bytes: []const u8,
            cursor: usize = 0,
            entity_index: usize,
        };
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(self.allocator);
        const initial = self.state.string(self.state.entities.items[initial_index].value.?);
        try self.state.chargeEntity(
            self.limits,
            self.state.string(self.state.entities.items[initial_index].name).len +| 2,
            initial.len,
            offset,
        );
        try frames.append(self.allocator, .{
            .bytes = initial,
            .entity_index = initial_index,
        });
        while (frames.items.len != 0) {
            const frame = &frames.items[frames.items.len - 1];
            if (frame.cursor == frame.bytes.len) {
                _ = frames.pop();
                continue;
            }
            const amp = std.mem.indexOfScalarPos(u8, frame.bytes, frame.cursor, '&') orelse {
                if (std.mem.indexOfScalar(u8, frame.bytes[frame.cursor..], '<') != null) {
                    return self.invalid(.malformed_attribute_list, offset);
                }
                try self.appendReplacement(output, frame.bytes[frame.cursor..], offset);
                frame.cursor = frame.bytes.len;
                continue;
            };
            const prefix = frame.bytes[frame.cursor..amp];
            if (std.mem.indexOfScalar(u8, prefix, '<') != null) {
                return self.invalid(.malformed_attribute_list, offset);
            }
            try self.appendReplacement(output, prefix, offset);
            const end = std.mem.indexOfScalarPos(u8, frame.bytes, amp + 1, ';') orelse
                return self.invalid(.malformed_attribute_list, offset);
            const name = frame.bytes[amp + 1 .. end];
            frame.cursor = end + 1;
            if (predefined(name)) |replacement| {
                try self.appendReplacement(output, replacement, offset);
                continue;
            }
            const nested = try self.state.findGeneralEntity(self.limits, name) orelse
                return self.invalid(.malformed_attribute_list, offset);
            for (frames.items) |active| {
                if (active.entity_index == nested) {
                    return self.invalid(.malformed_entity_declaration, offset);
                }
            }
            if (frames.items.len == self.limits.max_active_entity_depth) {
                return self.limit(.entity_depth_limit, offset);
            }
            const entity = self.state.entities.items[nested];
            if (entity.value == null or entity.unparsed) {
                return self.invalid(.malformed_attribute_list, offset);
            }
            const nested_value = self.state.string(entity.value.?);
            try self.state.chargeEntity(
                self.limits,
                name.len +| 2,
                nested_value.len,
                offset,
            );
            try frames.append(self.allocator, .{
                .bytes = nested_value,
                .entity_index = nested,
            });
        }
    }

    fn appendReplacement(
        self: *Parser,
        output: *std.ArrayList(u8),
        bytes: []const u8,
        offset: usize,
    ) ParseError!void {
        const remaining = self.limits.max_entity_replacement_bytes -|
            self.state.replacement_bytes -| output.items.len;
        if (bytes.len > remaining) {
            return self.limit(.replacement_bytes_limit, offset);
        }
        output.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }

    fn pushParameterReference(self: *Parser) ParseError!void {
        const source_index = self.sources.items.len - 1;
        const source = self.sourceBytes(source_index);
        const reference_offset = self.logicalOffset();
        var cursor = self.sources.items[source_index].cursor + 1;
        const name = scanName(source, &cursor) orelse
            return self.invalid(.malformed_declaration, self.logicalOffset());
        if (cursor >= source.len or source[cursor] != ';') {
            return self.invalid(.malformed_declaration, self.logicalOffset());
        }
        self.sources.items[source_index].cursor = cursor + 1;
        const entity_index = try self.findParameterEntity(name, self.logicalOffset()) orelse
            return self.invalid(.undeclared_parameter_entity, self.logicalOffset());
        for (self.sources.items) |frame| {
            if (frame.entity_index == entity_index) {
                return self.invalid(.recursive_parameter_entity, self.logicalOffset());
            }
        }
        if (self.sources.items.len == self.limits.max_active_entity_depth) {
            return self.limit(.entity_depth_limit, self.logicalOffset());
        }
        const entity = self.state.entities.items[entity_index];
        var value: []const u8 = undefined;
        var storage: @TypeOf(self.sources.items[0].storage) = .arena;
        const including_external = self.sources.items[source_index].external;
        var replacement_base_id = if (entity.base_id) |base_id| self.state.string(base_id) else null;
        var replacement_source_id = self.sources.items[source_index].source_id;
        if (entity.value) |stored| {
            value = self.state.string(stored);
        } else {
            const provider = self.external_provider orelse
                return self.state.setUnsupported(.external_subset_unsupported, self.logicalOffset());
            const system_id = entity.external_id.system_id orelse
                return self.invalid(.malformed_entity_declaration, self.logicalOffset());
            const result = try provider.resolve(.{
                .kind = .parameter_entity,
                .name = self.state.string(entity.name),
                .public_id = if (entity.external_id.public_id) |public|
                    self.state.string(public)
                else
                    null,
                .system_id = self.state.string(system_id),
                .base_id = if (entity.base_id) |base_id| self.state.string(base_id) else null,
                .inclusion_source_id = self.sources.items[source_index].source_id,
                .inclusion_offset = reference_offset,
            });
            switch (result) {
                .content => |content| {
                    value = content.bytes;
                    storage = .borrowed;
                    replacement_base_id = content.base_id;
                    replacement_source_id = content.source_id;
                },
                .skipped => {
                    try self.state.chargeEntity(
                        self.limits,
                        name.len +| 2,
                        0,
                        reference_offset,
                    );
                    const skipped_index = self.state.skipped_external.items.len;
                    try self.state.skipped_external.append(self.allocator, .{
                        .kind = .parameter_entity,
                        .name = entity.name,
                        .public_id = entity.external_id.public_id,
                        .system_id = system_id,
                        .offset = reference_offset,
                    });
                    try self.state.reports.append(self.allocator, .{
                        .kind = .skipped_external,
                        .index = skipped_index,
                    });
                    return;
                },
            }
        }
        try self.state.chargeEntity(
            self.limits,
            name.len +| 2,
            value.len,
            self.logicalOffset(),
        );
        self.state.parameter_reference_seen = true;
        try self.sources.append(self.allocator, .{
            .storage = storage,
            .offset = if (entity.value) |stored| stored.offset else 0,
            .len = value.len,
            .bytes = if (storage == .borrowed) value else &.{},
            .base_id = replacement_base_id,
            .source_id = replacement_source_id,
            .entity_index = entity_index,
            .reference_offset = reference_offset,
            .external = including_external or storage == .borrowed,
        });
    }

    fn findParameterEntity(self: *Parser, name: []const u8, offset: usize) ParseError!?usize {
        const name_hash = std.hash.Wyhash.hash(0, name);
        for (self.state.entities.items, 0..) |entity, index| {
            if (!entity.parameter) continue;
            if (entity.name_hash != name_hash) continue;
            try self.state.chargeComparison(self.limits, name.len +| entity.name.len +| 1, offset);
            if (std.mem.eql(u8, name, self.state.string(entity.name))) return index;
        }
        return null;
    }

    fn entityExists(
        self: *Parser,
        name: []const u8,
        parameter: bool,
        offset: usize,
    ) ParseError!bool {
        const name_hash = std.hash.Wyhash.hash(0, name);
        for (self.state.entities.items) |entity| {
            if (entity.parameter != parameter) continue;
            if (entity.name_hash != name_hash) continue;
            try self.state.chargeComparison(self.limits, name.len +| entity.name.len +| 1, offset);
            if (std.mem.eql(u8, name, self.state.string(entity.name))) return true;
        }
        return false;
    }

    fn attributeExists(
        self: *Parser,
        element_name: []const u8,
        name: []const u8,
        offset: usize,
    ) ParseError!bool {
        for (self.state.attributes.items) |attribute| {
            try self.state.chargeComparison(
                self.limits,
                element_name.len +| attribute.element_name.len +|
                    name.len +| attribute.name.len +| 2,
                offset,
            );
            if (std.mem.eql(u8, element_name, self.state.string(attribute.element_name)) and
                std.mem.eql(u8, name, self.state.string(attribute.name)))
            {
                return true;
            }
        }
        return false;
    }

    fn diagnosticOffset(self: *Parser, source_index: ?usize, cursor: usize) usize {
        return if (source_index) |index| self.sourceOffset(index, cursor) else cursor;
    }

    fn ensureSource(self: *Parser) ParseError!bool {
        while (self.sources.items.len != 0) {
            const index = self.sources.items.len - 1;
            if (self.sources.items[index].cursor < self.sources.items[index].len) return true;
            _ = self.sources.pop();
        }
        return false;
    }

    fn skipLogicalWhitespace(self: *Parser) ParseError!void {
        while (try self.ensureSource()) {
            const index = self.sources.items.len - 1;
            const source = self.sourceBytes(index);
            var cursor = self.sources.items[index].cursor;
            skipWhitespace(source, &cursor);
            self.sources.items[index].cursor = cursor;
            if (cursor != source.len) return;
        }
    }

    fn peek(self: *Parser) u8 {
        const index = self.sources.items.len - 1;
        return self.sourceBytes(index)[self.sources.items[index].cursor];
    }

    fn sourceBytes(self: *Parser, index: usize) []const u8 {
        const source = self.sources.items[index];
        return switch (source.storage) {
            .subset => self.subset[source.offset..][0..source.len],
            .arena => self.state.bytes.items[source.offset..][0..source.len],
            .borrowed => source.bytes[source.offset..][0..source.len],
        };
    }

    fn sourceOffset(self: *Parser, source_index: usize, cursor: usize) usize {
        const source = self.sources.items[source_index];
        return switch (source.storage) {
            .subset => source.offset + cursor,
            .borrowed => cursor,
            .arena => source.reference_offset,
        };
    }

    fn logicalOffset(self: *Parser) usize {
        const index = self.sources.items.len - 1;
        return self.sourceOffset(index, self.sources.items[index].cursor);
    }

    fn chargeDeclarationBytes(
        self: *Parser,
        source: []const u8,
        start: usize,
        offset: usize,
    ) ParseError!void {
        const remaining = self.limits.max_declaration_bytes -| self.state.declaration_bytes;
        const end = declarationEnd(source, start, remaining) orelse return;
        const bytes = end - start;
        if (bytes > remaining) return self.limit(.declaration_bytes_limit, offset);
        self.state.declaration_bytes += bytes;
    }

    fn chargeGrammarNode(self: *Parser, offset: usize) ParseError!void {
        if (self.state.grammar_nodes == self.limits.max_grammar_nodes) {
            return self.limit(.grammar_node_limit, offset);
        }
        self.state.grammar_nodes += 1;
    }

    fn invalid(self: *Parser, code: ErrorCode, offset: usize) ParseError {
        self.state.failure = .{
            .code = code,
            .offset = offset,
            .source_id = if (self.sources.items.len == 0)
                self.diagnostic_source_id
            else
                self.sources.items[self.sources.items.len - 1].source_id,
        };
        return error.InvalidDtd;
    }

    fn limit(self: *Parser, code: ErrorCode, offset: usize) ParseError {
        self.state.failure = .{
            .code = code,
            .offset = offset,
            .source_id = if (self.sources.items.len == 0)
                self.diagnostic_source_id
            else
                self.sources.items[self.sources.items.len - 1].source_id,
        };
        return error.LimitExceeded;
    }
};

fn declarationEnd(bytes: []const u8, start: usize, limit: usize) ?usize {
    const Kind = enum { markup, comment, processing_instruction };
    const kind: Kind = if (std.mem.startsWith(u8, bytes[start..], "<!--"))
        .comment
    else if (std.mem.startsWith(u8, bytes[start..], "<?"))
        .processing_instruction
    else
        .markup;
    var cursor = start;
    var quote: u8 = 0;
    while (cursor < bytes.len) : (cursor += 1) {
        if (cursor - start == limit) return start +| limit +| 1;
        const byte = bytes[cursor];
        switch (kind) {
            .comment => if (byte == '>' and cursor >= start + 2 and
                std.mem.eql(u8, bytes[cursor - 2 .. cursor + 1], "-->"))
            {
                return cursor + 1;
            },
            .processing_instruction => if (byte == '>' and cursor > start and
                bytes[cursor - 1] == '?')
            {
                return cursor + 1;
            },
            .markup => {
                if (quote != 0) {
                    if (byte == quote) quote = 0;
                } else if (byte == '\'' or byte == '"') {
                    quote = byte;
                } else if (byte == '>') {
                    return cursor + 1;
                }
            },
        }
    }
    return null;
}

fn findSubsetEnd(bytes: []const u8, start: usize) ?usize {
    var cursor = start;
    var quote: u8 = 0;
    while (cursor < bytes.len) : (cursor += 1) {
        const byte = bytes[cursor];
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (std.mem.startsWith(u8, bytes[cursor..], "<!--")) {
            const close = std.mem.indexOfPos(u8, bytes, cursor + 4, "-->") orelse return null;
            cursor = close + 2;
        } else if (std.mem.startsWith(u8, bytes[cursor..], "<?")) {
            const close = std.mem.indexOfPos(u8, bytes, cursor + 2, "?>") orelse return null;
            cursor = close + 1;
        } else if (byte == ']') {
            return cursor;
        }
    }
    return null;
}

fn skipWhitespace(bytes: []const u8, cursor: *usize) void {
    while (cursor.* < bytes.len and isWhitespace(bytes[cursor.*])) cursor.* += 1;
}

fn requireWhitespace(bytes: []const u8, cursor: *usize) bool {
    const start = cursor.*;
    skipWhitespace(bytes, cursor);
    return cursor.* != start;
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn scanName(bytes: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    const first = scanCodepoint(bytes, cursor) orelse return null;
    if (!isNameStart(first)) {
        cursor.* = start;
        return null;
    }
    while (cursor.* < bytes.len) {
        const before = cursor.*;
        const value = scanCodepoint(bytes, cursor) orelse {
            cursor.* = start;
            return null;
        };
        if (!isNameChar(value)) {
            cursor.* = before;
            break;
        }
    }
    return bytes[start..cursor.*];
}

fn scanNmtoken(bytes: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    while (cursor.* < bytes.len) {
        const before = cursor.*;
        const value = scanCodepoint(bytes, cursor) orelse {
            cursor.* = start;
            return null;
        };
        if (!isNameChar(value)) {
            cursor.* = before;
            break;
        }
    }
    return if (cursor.* == start) null else bytes[start..cursor.*];
}

fn scanCodepoint(bytes: []const u8, cursor: *usize) ?u21 {
    if (cursor.* >= bytes.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor.*]) catch return null;
    if (len > bytes.len - cursor.*) return null;
    const value = std.unicode.utf8Decode(bytes[cursor.*..][0..len]) catch return null;
    cursor.* += len;
    return value;
}

fn isNameStart(value: u21) bool {
    return value == ':' or value == '_' or
        (value >= 'A' and value <= 'Z') or
        (value >= 'a' and value <= 'z') or
        (value >= 0xc0 and value <= 0xd6) or
        (value >= 0xd8 and value <= 0xf6) or
        (value >= 0xf8 and value <= 0x2ff) or
        (value >= 0x370 and value <= 0x37d) or
        (value >= 0x37f and value <= 0x1fff) or
        (value >= 0x200c and value <= 0x200d) or
        (value >= 0x2070 and value <= 0x218f) or
        (value >= 0x2c00 and value <= 0x2fef) or
        (value >= 0x3001 and value <= 0xd7ff) or
        (value >= 0xf900 and value <= 0xfdcf) or
        (value >= 0xfdf0 and value <= 0xfffd) or
        (value >= 0x10000 and value <= 0xeffff);
}

fn isNameChar(value: u21) bool {
    return isNameStart(value) or value == '-' or value == '.' or
        (value >= '0' and value <= '9') or value == 0xb7 or
        (value >= 0x300 and value <= 0x36f) or
        (value >= 0x203f and value <= 0x2040);
}

fn scanQuoted(bytes: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= bytes.len or (bytes[cursor.*] != '\'' and bytes[cursor.*] != '"')) return null;
    const quote = bytes[cursor.*];
    cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != quote) cursor.* += 1;
    if (cursor.* == bytes.len) return null;
    const value = bytes[start..cursor.*];
    cursor.* += 1;
    return value;
}

fn startsKeyword(bytes: []const u8, cursor: usize, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, bytes[cursor..], keyword)) return false;
    const end = cursor + keyword.len;
    if (end == bytes.len) return true;
    var next = end;
    const value = scanCodepoint(bytes, &next) orelse return false;
    return !isNameChar(value);
}

fn validPublicId(bytes: []const u8) bool {
    for (bytes) |byte| switch (byte) {
        0x20,
        0x0d,
        0x0a,
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '-',
        '\'',
        '(',
        ')',
        '+',
        ',',
        '.',
        '/',
        ':',
        '=',
        '?',
        ';',
        '!',
        '*',
        '#',
        '@',
        '$',
        '_',
        '%',
        => {},
        else => return false,
    };
    return true;
}

fn asciiEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    return true;
}

fn predefined(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "amp")) return "&";
    if (std.mem.eql(u8, name, "lt")) return "<";
    if (std.mem.eql(u8, name, "gt")) return ">";
    if (std.mem.eql(u8, name, "apos")) return "'";
    if (std.mem.eql(u8, name, "quot")) return "\"";
    return null;
}

fn decodeCharacterReference(
    token: []const u8,
    output: *[4]u8,
    version: XmlVersion,
) ?usize {
    if (token.len < 2 or token[0] != '#') return null;
    const hexadecimal = token.len > 2 and token[1] == 'x';
    const digits = token[if (hexadecimal) 2 else 1..];
    if (digits.len == 0) return null;
    const value = std.fmt.parseInt(u21, digits, if (hexadecimal) 16 else 10) catch return null;
    if (!isXmlChar(value, version)) return null;
    return std.unicode.utf8Encode(value, output) catch null;
}

fn characterReferenceEquals(reference: []const u8, expected: u21, version: XmlVersion) bool {
    if (reference.len < 4 or reference[0] != '&' or reference[reference.len - 1] != ';') {
        return false;
    }
    var output: [4]u8 = undefined;
    const len = decodeCharacterReference(reference[1 .. reference.len - 1], &output, version) orelse
        return false;
    var expected_output: [4]u8 = undefined;
    const expected_len = std.unicode.utf8Encode(expected, &expected_output) catch return false;
    return len == expected_len and std.mem.eql(u8, output[0..len], expected_output[0..expected_len]);
}

fn isXml10Char(value: u21) bool {
    return value == 0x9 or value == 0xa or value == 0xd or
        (value >= 0x20 and value <= 0xd7ff) or
        (value >= 0xe000 and value <= 0xfffd) or
        (value >= 0x10000 and value <= 0x10ffff);
}

fn isXmlChar(value: u21, version: XmlVersion) bool {
    return switch (version) {
        .xml10 => isXml10Char(value),
        .xml11 => value >= 0x1 and value <= 0xd7ff or
            value >= 0xe000 and value <= 0xfffd or
            value >= 0x10000 and value <= 0x10ffff,
    };
}

pub fn collapseSpaces(bytes: []u8) usize {
    var read: usize = 0;
    var write: usize = 0;
    var pending_space = false;
    while (read < bytes.len) : (read += 1) {
        if (bytes[read] == ' ') {
            if (write != 0) pending_space = true;
        } else {
            if (pending_space) {
                bytes[write] = ' ';
                write += 1;
                pending_space = false;
            }
            bytes[write] = bytes[read];
            write += 1;
        }
    }
    return write;
}

pub fn validName(bytes: []const u8) bool {
    var cursor: usize = 0;
    const name = scanName(bytes, &cursor) orelse return false;
    return name.len == bytes.len and cursor == bytes.len;
}

pub fn validNmtoken(bytes: []const u8) bool {
    var cursor: usize = 0;
    const token = scanNmtoken(bytes, &cursor) orelse return false;
    return token.len == bytes.len and cursor == bytes.len;
}

fn expectLimitBoundaryForTest(
    comptime field_name: []const u8,
    doctype: []const u8,
    boundary: usize,
    code: ErrorCode,
) !void {
    var at_state: State = .{};
    defer at_state.deinit(std.testing.allocator);
    try at_state.doctype_bytes.appendSlice(std.testing.allocator, doctype);
    var at_limits: Limits = .{};
    @field(at_limits, field_name) = boundary;
    try at_state.parseDoctype(std.testing.allocator, at_limits);

    var over_state: State = .{};
    defer over_state.deinit(std.testing.allocator);
    try over_state.doctype_bytes.appendSlice(std.testing.allocator, doctype);
    var over_limits: Limits = .{};
    @field(over_limits, field_name) = boundary - 1;
    try std.testing.expectError(
        error.LimitExceeded,
        over_state.parseDoctype(std.testing.allocator, over_limits),
    );
    try std.testing.expectEqual(code, over_state.failure.?.code);
}

// --- Tests ---

test "[unit] - [DTD parser]: stores declarations and normalized defaults" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try state.doctype_bytes.appendSlice(
        std.testing.allocator,
        " root [<!ELEMENT root (#PCDATA|child)*><!ELEMENT child EMPTY>" ++
            "<!ATTLIST root mode ( one | two ) '  one  '>" ++
            "<!ENTITY text 'value'><!NOTATION image PUBLIC 'image/type'>" ++
            "<!ENTITY logo SYSTEM 'logo.bin' NDATA image>]>",
    );
    try state.parseDoctype(std.testing.allocator, .{});

    try std.testing.expectEqualStrings("root", state.rootName());
    try std.testing.expectEqual(@as(usize, 2), state.elements.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.attributes.items.len);
    try std.testing.expectEqualStrings(
        "one",
        state.string(state.attributes.items[0].default_value.?),
    );
    try std.testing.expectEqual(@as(usize, 2), state.entities.items.len);
    try std.testing.expect(state.entities.items[1].unparsed);
    try std.testing.expectEqual(@as(usize, 1), state.notations.items.len);
}

test "[unit] - [DTD parser]: parameter entity supplies complete declarations" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try state.doctype_bytes.appendSlice(
        std.testing.allocator,
        " root [<!ENTITY % declaration '<!ELEMENT root EMPTY>'>%declaration;]>",
    );
    try state.parseDoctype(std.testing.allocator, .{});
    try std.testing.expectEqual(@as(usize, 1), state.elements.items.len);

    state.clearRetainingCapacity();
    try state.doctype_bytes.appendSlice(
        std.testing.allocator,
        " root [<!ENTITY % loop '%loop;'>%loop;]>",
    );
    try std.testing.expectError(
        error.InvalidDtd,
        state.parseDoctype(std.testing.allocator, .{}),
    );
    try std.testing.expectEqual(ErrorCode.malformed_entity_declaration, state.failure.?.code);
}

test "[failure] - [DTD parser]: rejects invalid predefined entity declarations" {
    inline for (.{
        " root [<!ENTITY lt '&#60;'>]>",
        " root [<!ENTITY amp '&#38;'>]>",
        " root [<!ENTITY gt 'wrong'>]>",
        " root [<!ENTITY apos 'wrong'>]>",
        " root [<!ENTITY quot 'wrong'>]>",
        " root [<!ENTITY amp SYSTEM 'amp.ent'>]>",
    }) |doctype| {
        var state: State = .{};
        defer state.deinit(std.testing.allocator);
        try state.doctype_bytes.appendSlice(std.testing.allocator, doctype);
        try std.testing.expectError(
            error.InvalidDtd,
            state.parseDoctype(std.testing.allocator, .{}),
        );
        try std.testing.expectEqual(ErrorCode.malformed_entity_declaration, state.failure.?.code);
    }

    inline for (.{
        " root [<!ENTITY lt '&#38;#60;'>]>",
        " root [<!ENTITY amp '&#38;#38;'>]>",
        " root [<!ENTITY gt '&#62;'>]>",
        " root [<!ENTITY apos \"'\">]>",
        " root [<!ENTITY quot '&#34;'>]>",
    }) |doctype| {
        var state: State = .{};
        defer state.deinit(std.testing.allocator);
        try state.doctype_bytes.appendSlice(std.testing.allocator, doctype);
        try state.parseDoctype(std.testing.allocator, .{});
    }
}

test "[failure] - [DTD limits]: declaration bytes fail before declaration storage" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try state.doctype_bytes.appendSlice(
        std.testing.allocator,
        " root [<!ELEMENT root EMPTY>]>",
    );
    var limits: Limits = .{};
    limits.max_declaration_bytes = "<!ELEMENT root EMPTY>".len - 1;

    try std.testing.expectError(
        error.LimitExceeded,
        state.parseDoctype(std.testing.allocator, limits),
    );
    try std.testing.expectEqual(ErrorCode.declaration_bytes_limit, state.failure.?.code);
    try std.testing.expectEqual(@as(usize, 0), state.elements.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.reports.items.len);
}

test "[edge] - [DTD limits]: structural limits accept the boundary and reject one over" {
    try expectLimitBoundaryForTest(
        "max_declarations",
        " root [<!ELEMENT root EMPTY><!ELEMENT child EMPTY>]>",
        2,
        .declaration_limit,
    );
    try expectLimitBoundaryForTest(
        "max_declaration_bytes",
        " root [<!ELEMENT root EMPTY>]>",
        "<!ELEMENT root EMPTY>".len,
        .declaration_bytes_limit,
    );
    try expectLimitBoundaryForTest(
        "max_element_declarations",
        " root [<!ELEMENT root EMPTY><!ELEMENT child EMPTY>]>",
        2,
        .element_declaration_limit,
    );
    try expectLimitBoundaryForTest(
        "max_attribute_declarations",
        " root [<!ATTLIST root a CDATA #IMPLIED b CDATA #IMPLIED>]>",
        2,
        .attribute_declaration_limit,
    );
    try expectLimitBoundaryForTest(
        "max_entity_declarations",
        " root [<!ENTITY a 'a'><!ENTITY b 'b'>]>",
        2,
        .entity_declaration_limit,
    );
    try expectLimitBoundaryForTest(
        "max_notation_declarations",
        " root [<!NOTATION a SYSTEM 'a'><!NOTATION b PUBLIC 'b'>]>",
        2,
        .notation_declaration_limit,
    );
    try expectLimitBoundaryForTest(
        "max_group_depth",
        " root [<!ELEMENT root (a,(b))>]>",
        2,
        .grammar_depth_limit,
    );
    try expectLimitBoundaryForTest(
        "max_grammar_nodes",
        " root [<!ELEMENT root (a,b)>]>",
        2,
        .grammar_node_limit,
    );
    try expectLimitBoundaryForTest(
        "max_entity_replacement_bytes",
        " root [<!ENTITY a 'ab'>]>",
        2,
        .replacement_bytes_limit,
    );
}

test "[edge] - [DTD retained declaration limits]: ignored duplicates do not consume slots" {
    var limits: Limits = .{};
    limits.max_entity_declarations = 1;
    var entity_state: State = .{};
    defer entity_state.deinit(std.testing.allocator);
    try entity_state.doctype_bytes.appendSlice(
        std.testing.allocator,
        " root [<!ENTITY value 'first'><!ENTITY value 'second'>]>",
    );
    try entity_state.parseDoctype(std.testing.allocator, limits);
    try std.testing.expectEqual(@as(usize, 1), entity_state.entities.items.len);
    try std.testing.expectEqualStrings(
        "first",
        entity_state.string(entity_state.entities.items[0].value.?),
    );

    limits = .{};
    limits.max_attribute_declarations = 1;
    var attribute_state: State = .{};
    defer attribute_state.deinit(std.testing.allocator);
    try attribute_state.doctype_bytes.appendSlice(
        std.testing.allocator,
        " root [<!ATTLIST root mode CDATA 'first' mode CDATA 'second'>]>",
    );
    try attribute_state.parseDoctype(std.testing.allocator, limits);
    try std.testing.expectEqual(@as(usize, 1), attribute_state.attributes.items.len);
    try std.testing.expectEqualStrings(
        "first",
        attribute_state.string(attribute_state.attributes.items[0].default_value.?),
    );
}

test "[edge] - [entity limits]: inclusion limits accept the boundary and reject one over" {
    const declaration = "<!ELEMENT root EMPTY>";
    const doctype = " root [<!ENTITY % a '&#60;!ELEMENT root EMPTY>'>%a;]>";
    try expectLimitBoundaryForTest(
        "max_active_entity_depth",
        doctype,
        2,
        .entity_depth_limit,
    );
    try expectLimitBoundaryForTest(
        "max_entity_references",
        doctype,
        1,
        .entity_reference_limit,
    );
    try expectLimitBoundaryForTest(
        "max_expanded_bytes",
        doctype,
        declaration.len,
        .expanded_bytes_limit,
    );
    try expectLimitBoundaryForTest(
        "max_comparison_work",
        doctype,
        3,
        .comparison_work_limit,
    );
}

test "[edge] - [DTD byte limit]: append accepts the boundary and rejects one over" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var limits: Limits = .{};
    limits.max_dtd_bytes = 1;

    try state.appendDoctypeByte(std.testing.allocator, limits, 'x');
    try std.testing.expectError(
        error.LimitExceeded,
        state.appendDoctypeByte(std.testing.allocator, limits, 'y'),
    );
    try std.testing.expectEqual(ErrorCode.dtd_bytes_limit, state.failure.?.code);
    try std.testing.expectEqualStrings("x", state.doctype_bytes.items);
}

test "[unit] - [DTD parser]: accepts public-only notation and close bracket in PI" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try state.doctype_bytes.appendSlice(
        std.testing.allocator,
        " root [<?inside ] data?><!ELEMENT root EMPTY>" ++
            "<!NOTATION note PUBLIC 'public-id'>]>",
    );
    try state.parseDoctype(std.testing.allocator, .{});
    try std.testing.expectEqual(@as(usize, 1), state.elements.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.notations.items.len);
}

test "[unit] - [DTD parser]: enforces mixed and children grammar" {
    inline for (.{
        " root [<!ELEMENT root (a,(b|c)+)>]>",
        " root [<!ELEMENT root (#PCDATA)>]>",
        " root [<!ELEMENT root (#PCDATA|child)*>]>",
    }) |doctype| {
        var state: State = .{};
        defer state.deinit(std.testing.allocator);
        try state.doctype_bytes.appendSlice(std.testing.allocator, doctype);
        try state.parseDoctype(std.testing.allocator, .{});
    }
    inline for (.{
        " root [<!ELEMENT root (#PCDATA,child)*>]>",
        " root [<!ELEMENT root (#PCDATA|child)>]>",
        " root [<!ELEMENT root (a|b,c)>]>",
        " root [<!ELEMENT root ()>]>",
    }) |doctype| {
        var state: State = .{};
        defer state.deinit(std.testing.allocator);
        try state.doctype_bytes.appendSlice(std.testing.allocator, doctype);
        try std.testing.expectError(
            error.InvalidDtd,
            state.parseDoctype(std.testing.allocator, .{}),
        );
    }
}
