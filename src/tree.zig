//! Builds an immutable, caller-owned document tree from public reader events.
//!
//! Document-scoped indices remain valid until `Document.deinit`. All strings
//! returned by navigation methods borrow from the document byte pool.
//! Initialized builders and completed documents are single owners. Moving one
//! invalidates the source value; copying one is not supported.

const std = @import("std");

const dtd = @import("dtd.zig");
const reader = @import("reader.zig");

/// Index zero represents no node.
pub const NodeIndex = u32;

/// Kinds retained in the document node array.
pub const NodeKind = enum(u8) {
    document,
    element,
    text,
    comment,
    processing_instruction,
};

/// Limits applied independently of parser limits.
/// Node counts include the synthetic document node. `max_tree_bytes` covers
/// dynamic capacity retained by the document, not temporary builder stacks.
pub const Limits = struct {
    /// Finite default limits for normal and specialized documents.
    pub const general: Limits = .{};

    max_nodes: usize = 32 * 1024 * 1024,
    max_attributes: usize = 16 * 1024 * 1024,
    max_namespace_declarations: usize = 4 * 1024 * 1024,
    max_string_bytes: usize = 1024 * 1024 * 1024,
    max_children_per_element: usize = 16 * 1024 * 1024,
    max_coalesced_text_bytes: usize = 64 * 1024 * 1024,
    max_tree_bytes: usize = 2 * 1024 * 1024 * 1024,

    fn valid(self: Limits) bool {
        return self.max_nodes > 0 and
            self.max_attributes > 0 and
            self.max_namespace_declarations > 0 and
            self.max_string_bytes > 0 and
            self.max_children_per_element > 0 and
            self.max_coalesced_text_bytes > 0 and
            self.max_tree_bytes > 0;
    }
};

/// Limits applied to normal Document construction and retained storage.
pub const DocumentLimits = struct {
    /// Finite default limits for normal documents.
    pub const general: DocumentLimits = .{};

    max_nodes: usize = 32 * 1024 * 1024,
    max_attributes: usize = 16 * 1024 * 1024,
    max_namespace_declarations: usize = 4 * 1024 * 1024,
    max_string_bytes: usize = 1024 * 1024 * 1024,
    max_children_per_element: usize = 16 * 1024 * 1024,
    max_coalesced_text_bytes: usize = 64 * 1024 * 1024,
    max_retained_bytes: usize = 2 * 1024 * 1024 * 1024,

    fn valid(self: DocumentLimits) bool {
        return self.max_nodes > 0 and
            self.max_attributes > 0 and
            self.max_namespace_declarations > 0 and
            self.max_string_bytes > 0 and
            self.max_children_per_element > 0 and
            self.max_coalesced_text_bytes > 0 and
            self.max_retained_bytes > 0;
    }
};

/// Optional initial capacities for callers that know document statistics.
pub const CapacityHints = struct {
    nodes: usize = 0,
    attributes: usize = 0,
    namespace_declarations: usize = 0,
    string_bytes: usize = 0,
};

/// Runtime tree construction choices.
pub const Options = struct {
    limits: Limits = .{},
    capacity_hints: CapacityHints = .{},
    /// Keeps CDATA and character data in separate nodes with their original origins.
    /// When false, compatible text is merged and reported as character data.
    preserve_cdata_origin: bool = true,
};

/// Errors produced by tree construction independently of XML parsing.
pub const BuildError = error{
    InvalidOptions,
    InvalidEventSequence,
    TreeLimit,
    OutOfMemory,
};

/// Owned-capacity categories for a completed document.
/// `node_capacity_bytes` includes nodes and their kind-specific payload arrays.
pub const MemoryUsage = struct {
    node_count: usize,
    node_capacity_bytes: usize,
    attribute_count: usize,
    attribute_capacity_bytes: usize,
    namespace_declaration_count: usize,
    namespace_declaration_capacity_bytes: usize,
    string_bytes: usize,
    string_capacity_bytes: usize,
    location_capacity_bytes: usize,
    dtd_metadata_capacity_bytes: usize,
    total_capacity_bytes: usize,
};

/// Logical counts and retained allocation capacities owned by a normal document.
pub const DocumentMemoryUsage = struct {
    node_count: usize,
    node_capacity_bytes: usize,
    attribute_count: usize,
    attribute_capacity_bytes: usize,
    namespace_declaration_count: usize,
    namespace_declaration_capacity_bytes: usize,
    string_bytes: usize,
    string_capacity_bytes: usize,
    metadata_capacity_bytes: usize,
    total_capacity_bytes: usize,
};

/// Runtime options for normal owned-document construction.
pub const DocumentOptions = struct {
    reader: reader.NormalReaderOptions = .{},
    limits: DocumentLimits = DocumentLimits.general,
    retain_comments: bool = true,
    retain_processing_instructions: bool = true,
    retain_text_origin: bool = false,
};

/// Errors returned while parsing a normal owned document.
pub const ParseDocumentError = reader.NormalReadError || error{
    InvalidOptions,
    InvalidEventSequence,
    DocumentLimit,
};

/// Name whose slices borrow from the document.
pub const Name = struct {
    raw: []const u8,
    prefix: ?[]const u8,
    local: []const u8,
    namespace_uri: ?[]const u8,
};

/// Attribute whose slices borrow from the document.
pub const Attribute = struct {
    name: Name,
    value: []const u8,
    specified: bool,
    declared_type: ?dtd.AttributeType,
};

/// Namespace declaration whose slices borrow from the document.
pub const NamespaceDeclaration = struct {
    prefix: ?[]const u8,
    namespace_uri: []const u8,
};

/// XML declaration information retained from `document_start`.
pub const Declaration = struct {
    effective_version: reader.XmlVersion,
    declared_version: ?[]const u8,
    source_encoding: reader.SourceEncoding,
    declared_encoding: ?[]const u8,
    standalone: bool,
    standalone_declared: bool,
};

/// Document type header whose slices borrow from the document.
pub const DocumentType = struct {
    root_name: []const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
};

/// DTD information made visible by the selected reader report.
pub const DtdRecordKind = enum(u8) {
    notation,
    unparsed_entity,
    element,
    attribute_list,
    parsed_entity,
    skipped_entity,
    entity_start,
    entity_end,
};

/// One source-ordered DTD report whose slices borrow from the document.
pub const DtdRecord = struct {
    kind: DtdRecordKind,
    name: ?[]const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
    notation_name: ?[]const u8,
    skipped_entity_kind: ?reader.SkippedEntityKind,
};

const StoredNormalDtdFinding = struct {
    code: reader.DiagnosticCode,
    primary: reader.NormalLocation,
    related: ?reader.NormalLocation,
};

const StringRef = struct {
    offset: u32 = std.math.maxInt(u32),
    len: u32 = 0,
};

const Node = struct {
    parent: NodeIndex = 0,
    first_child: NodeIndex = 0,
    next_sibling: NodeIndex = 0,
    payload: u32 = 0,
    kind: NodeKind,
};

const DocumentNameRecord = struct {
    raw: StringRef,
    prefix: StringRef = .{},
    local: StringRef = .{},
    namespace_uri: StringRef = .{},
};

const DocumentElementRecord = struct {
    name: DocumentNameRecord,
    attribute_start: u32,
    attribute_count: u32,
    namespace_start: u32,
    namespace_count: u32,
};

const DocumentAttributeRecord = struct {
    name: DocumentNameRecord,
    value: StringRef,
    declared_type: u8 = 0,
    specified: bool = true,
    has_declared_type: bool = false,
};

const NamespaceRecord = struct {
    prefix: StringRef,
    namespace_uri: StringRef,
};

const PiRecord = struct {
    target: StringRef,
    data: StringRef,
};

const StoredDocumentStart = struct {
    effective_version: reader.XmlVersion,
    source_encoding: reader.SourceEncoding,
    declaration_present: bool,
    declared_version: reader.XmlVersion,
    declared_encoding: StringRef,
    standalone: bool,
    standalone_declared: bool,
};

const StoredDocumentType = struct {
    root_name: StringRef,
    public_id: StringRef,
    system_id: StringRef,
};

/// Immutable XML document owned independently of its source and Reader.
///
/// After assignment or return, only the destination may be used. Using or
/// deinitializing both copies is not supported. Values returned by query methods
/// borrow from the document and expire on `deinit`.
pub const Document = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    elements: std.ArrayList(DocumentElementRecord),
    attributes_storage: std.ArrayList(DocumentAttributeRecord),
    namespace_storage: std.ArrayList(NamespaceRecord),
    texts: std.ArrayList(StringRef),
    text_origins: std.ArrayList(reader.TextOrigin),
    comments: std.ArrayList(StringRef),
    processing_instructions: std.ArrayList(PiRecord),
    strings: std.ArrayList(u8),
    dtd_finding_inclusions: std.ArrayList(reader.NormalLocation),
    start_result: StoredDocumentStart,
    document_type: ?StoredDocumentType,
    document_element: NodeIndex,
    end_result: reader.NormalDocumentEnd,
    first_dtd_finding: ?StoredNormalDtdFinding,
    normalization_finding: ?reader.NormalNormalizationFinding,
    namespaces_processed: bool,
    text_origin_retained: bool,

    /// Releases all document-owned storage. Call exactly once for each owned value.
    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
        self.elements.deinit(self.allocator);
        self.attributes_storage.deinit(self.allocator);
        self.namespace_storage.deinit(self.allocator);
        self.texts.deinit(self.allocator);
        self.text_origins.deinit(self.allocator);
        self.comments.deinit(self.allocator);
        self.processing_instructions.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.dtd_finding_inclusions.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns the synthetic document node.
    pub fn root(self: *const Self) NodeIndex {
        _ = self;
        return 1;
    }

    /// Returns the document's single element node.
    pub fn documentElement(self: *const Self) NodeIndex {
        return self.document_element;
    }

    /// Returns a node kind, or null for an invalid index.
    pub fn nodeKind(self: *const Self, node: NodeIndex) ?NodeKind {
        const value = self.getNode(node) orelse return null;
        return value.kind;
    }

    /// Returns a node's parent, or zero for an invalid node or the document node.
    pub fn parent(self: *const Self, node: NodeIndex) NodeIndex {
        const value = self.getNode(node) orelse return 0;
        return value.parent;
    }

    /// Returns an allocation-free iterator over source-ordered child nodes.
    pub fn children(self: *const Self, node: NodeIndex) ChildIterator {
        const value = self.getNode(node) orelse return .{ .document = self, .next_node = 0 };
        return .{ .document = self, .next_node = value.first_child };
    }

    /// Returns an element name, or null for another node kind or an invalid index.
    pub fn nodeName(self: *const Self, node: NodeIndex) ?reader.NormalName {
        const value = self.getNode(node) orelse return null;
        if (value.kind != .element) return null;
        return self.normalName(self.elements.items[value.payload].name);
    }

    /// Returns text or comment bytes, or null for another node kind or an invalid index.
    pub fn nodeValue(self: *const Self, node: NodeIndex) ?[]const u8 {
        const value = self.getNode(node) orelse return null;
        return switch (value.kind) {
            .text => self.bytes(self.texts.items[value.payload]),
            .comment => self.bytes(self.comments.items[value.payload]),
            else => null,
        };
    }

    /// Returns retained text origin, or null when origin retention is disabled.
    pub fn textOrigin(self: *const Self, node: NodeIndex) ?reader.TextOrigin {
        if (!self.text_origin_retained) return null;
        const value = self.getNode(node) orelse return null;
        if (value.kind != .text) return null;
        return self.text_origins.items[value.payload];
    }

    /// Returns a processing instruction, or null for another node kind or an invalid index.
    pub fn processingInstruction(
        self: *const Self,
        node: NodeIndex,
    ) ?struct { target: []const u8, data: []const u8 } {
        const value = self.getNode(node) orelse return null;
        if (value.kind != .processing_instruction) return null;
        const instruction = self.processing_instructions.items[value.payload];
        return .{ .target = self.bytes(instruction.target), .data = self.bytes(instruction.data) };
    }

    /// Returns an allocation-free iterator over source-ordered attributes.
    pub fn attributes(self: *const Self, element: NodeIndex) AttributeIterator {
        return .{ .document = self, .element = element };
    }

    /// Finds an attribute by expanded identity, or returns null in raw-name mode.
    pub fn attribute(
        self: *const Self,
        element: NodeIndex,
        namespace_uri: ?[]const u8,
        local: []const u8,
    ) ?reader.NormalAttribute {
        if (!self.namespaces_processed) return null;
        var iterator = self.attributes(element);
        while (iterator.next()) |value| {
            if (value.name.eql(namespace_uri, local)) return value;
        }
        return null;
    }

    /// Finds an attribute by raw spelling.
    pub fn attributeRaw(
        self: *const Self,
        element: NodeIndex,
        raw: []const u8,
    ) ?reader.NormalAttribute {
        var iterator = self.attributes(element);
        while (iterator.next()) |value| {
            if (value.name.eqlRaw(raw)) return value;
        }
        return null;
    }

    /// Returns an allocation-free iterator over source-ordered namespace declarations.
    pub fn namespaceDeclarations(
        self: *const Self,
        element: NodeIndex,
    ) NamespaceDeclarationIterator {
        const record = if (self.namespaces_processed) self.getElement(element) else null;
        const count = if (record) |value| value.namespace_count else 0;
        return .{ .document = self, .element = element, .count = count };
    }

    /// Returns the effective document-start information and optional XML declaration.
    pub fn documentStart(self: *const Self) reader.NormalDocumentStart {
        const value = self.start_result;
        return .{
            .effective_version = value.effective_version,
            .source_encoding = value.source_encoding,
            .declaration = if (value.declaration_present) .{
                .version = value.declared_version,
                .encoding = self.optionalBytes(value.declared_encoding),
                .standalone = if (value.standalone_declared) value.standalone else null,
            } else null,
        };
    }

    /// Returns the optional document type header.
    pub fn documentType(self: *const Self) ?reader.NormalDocumentType {
        const value = self.document_type orelse return null;
        return .{
            .root_name = self.bytes(value.root_name),
            .public_id = self.optionalBytes(value.public_id),
            .system_id = self.optionalBytes(value.system_id),
        };
    }

    /// Returns the final Reader result retained by the document.
    pub fn documentEnd(self: *const Self) reader.NormalDocumentEnd {
        return self.end_result;
    }

    /// Returns the first DTD validity finding retained by the document.
    pub fn firstDtdFinding(self: *const Self) ?reader.NormalDtdFinding {
        const value = self.first_dtd_finding orelse return null;
        return .{
            .code = value.code,
            .primary = value.primary,
            .related = value.related,
            .inclusion_trace = self.dtd_finding_inclusions.items,
        };
    }

    /// Returns the first XML 1.1 normalization finding retained by the document.
    pub fn normalizationFinding(self: *const Self) ?reader.NormalNormalizationFinding {
        return self.normalization_finding;
    }

    /// Reports document-owned allocation counts and capacities.
    pub fn memoryUsage(self: *const Self) DocumentMemoryUsage {
        const node_bytes = self.nodes.capacity *| @sizeOf(Node) +|
            self.elements.capacity *| @sizeOf(DocumentElementRecord) +|
            self.texts.capacity *| @sizeOf(StringRef) +|
            self.text_origins.capacity *| @sizeOf(reader.TextOrigin) +|
            self.comments.capacity *| @sizeOf(StringRef) +|
            self.processing_instructions.capacity *| @sizeOf(PiRecord);
        const attribute_bytes = self.attributes_storage.capacity *|
            @sizeOf(DocumentAttributeRecord);
        const namespace_bytes = self.namespace_storage.capacity *| @sizeOf(NamespaceRecord);
        const metadata_bytes = self.dtd_finding_inclusions.capacity *|
            @sizeOf(reader.NormalLocation);
        return .{
            .node_count = self.nodes.items.len,
            .node_capacity_bytes = node_bytes,
            .attribute_count = self.attributes_storage.items.len,
            .attribute_capacity_bytes = attribute_bytes,
            .namespace_declaration_count = self.namespace_storage.items.len,
            .namespace_declaration_capacity_bytes = namespace_bytes,
            .string_bytes = self.strings.items.len,
            .string_capacity_bytes = self.strings.capacity,
            .metadata_capacity_bytes = metadata_bytes,
            .total_capacity_bytes = node_bytes +| attribute_bytes +| namespace_bytes +|
                self.strings.capacity +| metadata_bytes,
        };
    }

    fn normalName(self: *const Self, value: DocumentNameRecord) reader.NormalName {
        return .{
            .raw = self.bytes(value.raw),
            .expanded = if (self.namespaces_processed) .{
                .prefix = self.optionalBytes(value.prefix),
                .local = self.bytes(value.local),
                .namespace_uri = self.optionalBytes(value.namespace_uri),
            } else null,
        };
    }

    fn normalAttribute(self: *const Self, value: DocumentAttributeRecord) reader.NormalAttribute {
        return .{
            .name = self.normalName(value.name),
            .value = self.bytes(value.value),
            .span = null,
            .specified = value.specified,
            .declared_type = if (value.has_declared_type)
                @enumFromInt(value.declared_type)
            else
                null,
        };
    }

    fn nodeSlot(self: *const Self, index: NodeIndex) ?usize {
        if (index == 0) return null;
        const slot: usize = index - 1;
        if (slot >= self.nodes.items.len) return null;
        return slot;
    }

    fn getNode(self: *const Self, index: NodeIndex) ?Node {
        const slot = self.nodeSlot(index) orelse return null;
        return self.nodes.items[slot];
    }

    fn getElement(self: *const Self, index: NodeIndex) ?DocumentElementRecord {
        const value = self.getNode(index) orelse return null;
        if (value.kind != .element) return null;
        return self.elements.items[value.payload];
    }

    fn bytes(self: *const Self, value: StringRef) []const u8 {
        return self.strings.items[value.offset..][0..value.len];
    }

    fn optionalBytes(self: *const Self, value: StringRef) ?[]const u8 {
        if (value.offset == std.math.maxInt(u32)) return null;
        return self.bytes(value);
    }

    /// Iterates source-ordered child nodes.
    pub const ChildIterator = struct {
        document: *const Self,
        next_node: NodeIndex,

        /// Returns the next node, or null after the final child.
        pub fn next(self: *ChildIterator) ?NodeIndex {
            if (self.next_node == 0) return null;
            const current = self.next_node;
            self.next_node = self.document.getNode(current).?.next_sibling;
            return current;
        }
    };

    /// Iterates source-ordered attributes.
    pub const AttributeIterator = struct {
        document: *const Self,
        element: NodeIndex,
        offset: usize = 0,

        /// Returns the next attribute, or null after the final attribute.
        pub fn next(self: *AttributeIterator) ?reader.NormalAttribute {
            const element = self.document.getElement(self.element) orelse return null;
            if (self.offset >= element.attribute_count) return null;
            const value = self.document.attributes_storage.items[element.attribute_start + self.offset];
            self.offset += 1;
            return self.document.normalAttribute(value);
        }
    };

    /// Iterates source-ordered namespace declarations.
    pub const NamespaceDeclarationIterator = struct {
        document: *const Self,
        element: NodeIndex,
        count: usize,
        offset: usize = 0,

        /// Returns the next declaration, or null after the final declaration.
        pub fn next(self: *NamespaceDeclarationIterator) ?NamespaceDeclaration {
            if (self.offset >= self.count) return null;
            const element = self.document.getElement(self.element) orelse return null;
            const value = self.document.namespace_storage.items[element.namespace_start + self.offset];
            self.offset += 1;
            return .{
                .prefix = self.document.optionalBytes(value.prefix),
                .namespace_uri = self.document.bytes(value.namespace_uri),
            };
        }
    };
};

fn StoredName(comptime config: reader.Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            raw: StringRef,
            prefix: StringRef,
            local: StringRef,
            namespace_uri: StringRef,
        }
    else
        struct { raw: StringRef };
}

fn ElementRecord(comptime config: reader.Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            name: StoredName(config),
            attribute_start: u32,
            attribute_count: u32,
            namespace_start: u32,
            namespace_count: u32,
        }
    else
        struct {
            name: StoredName(config),
            attribute_start: u32,
            attribute_count: u32,
        };
}

fn AttributeRecord(comptime config: reader.Config) type {
    return if (config.profile.dtdMode() == .rejected)
        struct {
            name: StoredName(config),
            value: StringRef,
        }
    else
        struct {
            name: StoredName(config),
            value: StringRef,
            declared_type: u8 = 0,
            specified: bool = true,
            has_declared_type: bool = false,
        };
}

const TextRecord = struct {
    value: StringRef,
    origin: reader.TextOrigin,
    ignorable_whitespace: bool,
};

const StoredDeclaration = struct {
    effective_version: reader.XmlVersion,
    declared_version: StringRef,
    source_encoding: reader.SourceEncoding,
    declared_encoding: StringRef,
    standalone: bool,
    standalone_declared: bool,
};

const StoredDtdRecord = struct {
    kind: DtdRecordKind,
    name: StringRef = .{},
    public_id: StringRef = .{},
    system_id: StringRef = .{},
    notation_name: StringRef = .{},
    skipped_entity_kind: ?reader.SkippedEntityKind = null,
};

/// Returns the immutable document type specialized to a parser profile.
pub fn ProfileDocumentFor(comptime config: reader.Config) type {
    config.validate();
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node),
        elements: std.ArrayList(ElementRecord(config)),
        attributes: std.ArrayList(AttributeRecord(config)),
        namespaces: std.ArrayList(NamespaceRecord),
        texts: std.ArrayList(TextRecord),
        comments: std.ArrayList(StringRef),
        processing_instructions: std.ArrayList(PiRecord),
        strings: std.ArrayList(u8),
        locations: if (config.event_locations) std.ArrayList(reader.Location(config)) else void,
        dtd_records: std.ArrayList(StoredDtdRecord),
        declaration: StoredDeclaration,
        document_type: ?StoredDocumentType,
        document_element: NodeIndex,
        validation_status: ?reader.ValidationStatus,

        /// Releases all storage owned by the document.
        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.elements.deinit(self.allocator);
            self.attributes.deinit(self.allocator);
            self.namespaces.deinit(self.allocator);
            self.texts.deinit(self.allocator);
            self.comments.deinit(self.allocator);
            self.processing_instructions.deinit(self.allocator);
            self.strings.deinit(self.allocator);
            if (comptime config.event_locations) self.locations.deinit(self.allocator);
            self.dtd_records.deinit(self.allocator);
            self.* = undefined;
        }

        /// Returns the synthetic document node.
        pub fn root(self: *const Self) NodeIndex {
            _ = self;
            return 1;
        }

        /// Returns the single document element.
        pub fn documentElement(self: *const Self) NodeIndex {
            return self.document_element;
        }

        /// Returns a node kind, or null for an invalid index.
        pub fn nodeKind(self: *const Self, index: NodeIndex) ?NodeKind {
            const slot = self.nodeSlot(index) orelse return null;
            return self.nodes.items[slot].kind;
        }

        /// Returns a node's parent, or zero when it has no parent.
        pub fn parent(self: *const Self, index: NodeIndex) NodeIndex {
            const slot = self.nodeSlot(index) orelse return 0;
            return self.nodes.items[slot].parent;
        }

        /// Returns a node's first child, or zero when it has no children.
        pub fn firstChild(self: *const Self, index: NodeIndex) NodeIndex {
            const slot = self.nodeSlot(index) orelse return 0;
            return self.nodes.items[slot].first_child;
        }

        /// Returns the next source-ordered sibling, or zero when absent.
        pub fn nextSibling(self: *const Self, index: NodeIndex) NodeIndex {
            const slot = self.nodeSlot(index) orelse return 0;
            return self.nodes.items[slot].next_sibling;
        }

        /// Iterates source-ordered children without allocation.
        pub fn children(self: *const Self, index: NodeIndex) ProfileChildIteratorFor(config) {
            return .{ .document = self, .next_index = self.firstChild(index) };
        }

        /// Returns an element name, or null for a non-element or invalid index.
        pub fn nodeName(self: *const Self, index: NodeIndex) ?Name {
            const node = self.getNode(index) orelse return null;
            if (node.kind != .element) return null;
            return self.name(self.elements.items[node.payload].name);
        }

        /// Returns text or comment content, or null for other node kinds.
        pub fn nodeValue(self: *const Self, index: NodeIndex) ?[]const u8 {
            const node = self.getNode(index) orelse return null;
            return switch (node.kind) {
                .text => self.bytes(self.texts.items[node.payload].value),
                .comment => self.bytes(self.comments.items[node.payload]),
                else => null,
            };
        }

        /// Returns the retained semantic origin of a text node.
        pub fn textOrigin(self: *const Self, index: NodeIndex) ?reader.TextOrigin {
            const node = self.getNode(index) orelse return null;
            if (node.kind != .text) return null;
            return self.texts.items[node.payload].origin;
        }

        /// Reports whether validating parsing classified a text node as ignorable whitespace.
        pub fn isIgnorableWhitespace(self: *const Self, index: NodeIndex) bool {
            const node = self.getNode(index) orelse return false;
            return node.kind == .text and self.texts.items[node.payload].ignorable_whitespace;
        }

        /// Returns processing-instruction target and data slices.
        pub fn processingInstruction(
            self: *const Self,
            index: NodeIndex,
        ) ?struct { target: []const u8, data: []const u8 } {
            const node = self.getNode(index) orelse return null;
            if (node.kind != .processing_instruction) return null;
            const value = self.processing_instructions.items[node.payload];
            return .{ .target = self.bytes(value.target), .data = self.bytes(value.data) };
        }

        /// Returns the number of source-ordered attributes on an element.
        pub fn attributeCount(self: *const Self, element: NodeIndex) usize {
            const record = self.getElement(element) orelse return 0;
            return record.attribute_count;
        }

        /// Returns one source-ordered attribute.
        pub fn attributeAt(self: *const Self, element: NodeIndex, offset: usize) ?Attribute {
            const record = self.getElement(element) orelse return null;
            if (offset >= record.attribute_count) return null;
            return self.attribute(self.attributes.items[record.attribute_start + offset]);
        }

        /// Finds the first attribute with the requested raw name.
        pub fn attributeByRaw(self: *const Self, element: NodeIndex, raw: []const u8) ?Attribute {
            const record = self.getElement(element) orelse return null;
            const end = record.attribute_start + record.attribute_count;
            for (self.attributes.items[record.attribute_start..end]) |value| {
                if (std.mem.eql(u8, self.bytes(value.name.raw), raw)) return self.attribute(value);
            }
            return null;
        }

        /// Finds the first attribute with the requested expanded name.
        pub fn attributeByExpanded(
            self: *const Self,
            element: NodeIndex,
            namespace_uri: ?[]const u8,
            local: []const u8,
        ) ?Attribute {
            const record = self.getElement(element) orelse return null;
            const end = record.attribute_start + record.attribute_count;
            for (self.attributes.items[record.attribute_start..end]) |value| {
                const candidate = self.name(value.name);
                if (optionalEql(candidate.namespace_uri, namespace_uri) and
                    std.mem.eql(u8, candidate.local, local)) return self.attribute(value);
            }
            return null;
        }

        /// Returns the number of source-ordered namespace declarations on an element.
        pub fn namespaceDeclarationCount(self: *const Self, element: NodeIndex) usize {
            if (comptime !config.profile.hasNamespaces()) {
                return 0;
            }
            const record = self.getElement(element) orelse return 0;
            return record.namespace_count;
        }

        /// Returns one source-ordered namespace declaration.
        pub fn namespaceDeclarationAt(
            self: *const Self,
            element: NodeIndex,
            offset: usize,
        ) ?NamespaceDeclaration {
            if (comptime !config.profile.hasNamespaces()) {
                return null;
            }
            const record = self.getElement(element) orelse return null;
            if (offset >= record.namespace_count) return null;
            const value = self.namespaces.items[record.namespace_start + offset];
            return .{
                .prefix = self.optionalBytes(value.prefix),
                .namespace_uri = self.bytes(value.namespace_uri),
            };
        }

        /// Returns source location for a node when event locations are configured.
        pub fn location(self: *const Self, index: NodeIndex) if (config.event_locations)
            ?reader.Location(config)
        else
            void {
            if (comptime config.event_locations) {
                const slot = self.nodeSlot(index) orelse return null;
                return self.locations.items[slot];
            }
        }

        /// Returns retained XML declaration information.
        pub fn xmlDeclaration(self: *const Self) Declaration {
            return .{
                .effective_version = self.declaration.effective_version,
                .declared_version = self.optionalBytes(self.declaration.declared_version),
                .source_encoding = self.declaration.source_encoding,
                .declared_encoding = self.optionalBytes(self.declaration.declared_encoding),
                .standalone = self.declaration.standalone,
                .standalone_declared = self.declaration.standalone_declared,
            };
        }

        /// Returns the optional document type header.
        pub fn documentType(self: *const Self) ?DocumentType {
            const value = self.document_type orelse return null;
            return .{
                .root_name = self.bytes(value.root_name),
                .public_id = self.optionalBytes(value.public_id),
                .system_id = self.optionalBytes(value.system_id),
            };
        }

        /// Returns the final validation result for a validating configuration.
        pub fn validationStatus(self: *const Self) ?reader.ValidationStatus {
            return self.validation_status;
        }

        /// Returns the number of source-ordered DTD reports retained by the tree.
        pub fn dtdRecordCount(self: *const Self) usize {
            return self.dtd_records.items.len;
        }

        /// Returns one source-ordered DTD report.
        pub fn dtdRecordAt(self: *const Self, index: usize) ?DtdRecord {
            if (index >= self.dtd_records.items.len) return null;
            const value = self.dtd_records.items[index];
            return .{
                .kind = value.kind,
                .name = self.optionalBytes(value.name),
                .public_id = self.optionalBytes(value.public_id),
                .system_id = self.optionalBytes(value.system_id),
                .notation_name = self.optionalBytes(value.notation_name),
                .skipped_entity_kind = value.skipped_entity_kind,
            };
        }

        /// Reports logical counts and allocated capacities owned by the document.
        pub fn memoryUsage(self: *const Self) MemoryUsage {
            const location_bytes = if (comptime config.event_locations)
                self.locations.capacity * @sizeOf(reader.Location(config))
            else
                0;
            const dtd_bytes = self.dtd_records.capacity * @sizeOf(StoredDtdRecord);
            const nodes_bytes = self.nodes.capacity * @sizeOf(Node) +
                self.elements.capacity * @sizeOf(ElementRecord(config)) +
                self.texts.capacity * @sizeOf(TextRecord) +
                self.comments.capacity * @sizeOf(StringRef) +
                self.processing_instructions.capacity * @sizeOf(PiRecord);
            const attribute_bytes = self.attributes.capacity * @sizeOf(AttributeRecord(config));
            const namespace_bytes = self.namespaces.capacity * @sizeOf(NamespaceRecord);
            return .{
                .node_count = self.nodes.items.len,
                .node_capacity_bytes = nodes_bytes,
                .attribute_count = self.attributes.items.len,
                .attribute_capacity_bytes = attribute_bytes,
                .namespace_declaration_count = self.namespaces.items.len,
                .namespace_declaration_capacity_bytes = namespace_bytes,
                .string_bytes = self.strings.items.len,
                .string_capacity_bytes = self.strings.capacity,
                .location_capacity_bytes = location_bytes,
                .dtd_metadata_capacity_bytes = dtd_bytes,
                .total_capacity_bytes = nodes_bytes + attribute_bytes + namespace_bytes +
                    self.strings.capacity + location_bytes + dtd_bytes,
            };
        }

        fn nodeSlot(self: *const Self, index: NodeIndex) ?usize {
            if (index == 0) return null;
            const slot: usize = index - 1;
            if (slot >= self.nodes.items.len) return null;
            return slot;
        }

        fn getNode(self: *const Self, index: NodeIndex) ?Node {
            const slot = self.nodeSlot(index) orelse return null;
            return self.nodes.items[slot];
        }

        fn getElement(self: *const Self, index: NodeIndex) ?ElementRecord(config) {
            const value = self.getNode(index) orelse return null;
            if (value.kind != .element) return null;
            return self.elements.items[value.payload];
        }

        fn bytes(self: *const Self, value: StringRef) []const u8 {
            return self.strings.items[value.offset..][0..value.len];
        }

        fn optionalBytes(self: *const Self, value: StringRef) ?[]const u8 {
            if (value.offset == std.math.maxInt(u32)) return null;
            return self.bytes(value);
        }

        fn name(self: *const Self, value: StoredName(config)) Name {
            if (comptime config.profile.hasNamespaces()) return .{
                .raw = self.bytes(value.raw),
                .prefix = self.optionalBytes(value.prefix),
                .local = self.bytes(value.local),
                .namespace_uri = self.optionalBytes(value.namespace_uri),
            };
            const raw = self.bytes(value.raw);
            return .{ .raw = raw, .prefix = null, .local = raw, .namespace_uri = null };
        }

        fn attribute(self: *const Self, value: AttributeRecord(config)) Attribute {
            return .{
                .name = self.name(value.name),
                .value = self.bytes(value.value),
                .specified = if (comptime config.profile.dtdMode() == .rejected)
                    true
                else
                    value.specified,
                .declared_type = if (comptime config.profile.dtdMode() == .rejected)
                    null
                else if (value.has_declared_type)
                    @enumFromInt(value.declared_type)
                else
                    null,
            };
        }
    };
}

/// Returns the allocation-free child iterator specialized to a parser profile.
pub fn ProfileChildIteratorFor(comptime config: reader.Config) type {
    return struct {
        document: *const ProfileDocumentFor(config),
        next_index: NodeIndex,

        /// Returns the next child index, or null after the final child.
        pub fn next(self: *@This()) ?NodeIndex {
            if (self.next_index == 0) return null;
            const current = self.next_index;
            self.next_index = self.document.nextSibling(current);
            return current;
        }
    };
}

/// Returns an event consumer specialized to a parser profile.
pub fn ProfileBuilderFor(comptime config: reader.Config) type {
    config.validate();
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        options: Options,
        nodes: std.ArrayList(Node) = .empty,
        elements: std.ArrayList(ElementRecord(config)) = .empty,
        attributes: std.ArrayList(AttributeRecord(config)) = .empty,
        namespaces: std.ArrayList(NamespaceRecord) = .empty,
        texts: std.ArrayList(TextRecord) = .empty,
        comments: std.ArrayList(StringRef) = .empty,
        processing_instructions: std.ArrayList(PiRecord) = .empty,
        strings: std.ArrayList(u8) = .empty,
        locations: if (config.event_locations)
            std.ArrayList(reader.Location(config))
        else
            void = if (config.event_locations) .empty else {},
        dtd_records: std.ArrayList(StoredDtdRecord) = .empty,
        open_elements: std.ArrayList(NodeIndex) = .empty,
        last_children: std.ArrayList(NodeIndex) = .empty,
        open_child_counts: std.ArrayList(u32) = .empty,
        declaration: ?StoredDeclaration = null,
        document_type: ?StoredDocumentType = null,
        document_element: NodeIndex = 0,
        validation_status: ?reader.ValidationStatus = null,
        document_ended: bool = false,
        failed: bool = false,
        fragment_node: NodeIndex = 0,
        fragment_complete: bool = true,
        text_boundary: bool = false,

        /// Initializes an empty builder and applies optional capacity hints.
        pub fn init(allocator: std.mem.Allocator, options: Options) BuildError!Self {
            if (!options.limits.valid()) return error.InvalidOptions;
            if (options.capacity_hints.nodes > options.limits.max_nodes or
                options.capacity_hints.attributes > options.limits.max_attributes or
                options.capacity_hints.namespace_declarations >
                    options.limits.max_namespace_declarations or
                options.capacity_hints.string_bytes > options.limits.max_string_bytes)
                return error.InvalidOptions;

            const hinted_bytes = capacityBytes(
                config,
                options.capacity_hints.nodes,
                options.capacity_hints.attributes,
                options.capacity_hints.namespace_declarations,
                options.capacity_hints.string_bytes,
            ) catch return error.InvalidOptions;
            if (hinted_bytes > options.limits.max_tree_bytes) return error.InvalidOptions;

            var self = Self{ .allocator = allocator, .options = options };
            errdefer self.deinit();
            self.nodes.ensureTotalCapacityPrecise(allocator, options.capacity_hints.nodes) catch
                return error.OutOfMemory;
            self.attributes.ensureTotalCapacityPrecise(allocator, options.capacity_hints.attributes) catch
                return error.OutOfMemory;
            self.namespaces.ensureTotalCapacityPrecise(
                allocator,
                options.capacity_hints.namespace_declarations,
            ) catch return error.OutOfMemory;
            self.strings.ensureTotalCapacityPrecise(allocator, options.capacity_hints.string_bytes) catch
                return error.OutOfMemory;
            try self.checkCapacityLimit();
            return self;
        }

        /// Releases all partially constructed storage.
        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.elements.deinit(self.allocator);
            self.attributes.deinit(self.allocator);
            self.namespaces.deinit(self.allocator);
            self.texts.deinit(self.allocator);
            self.comments.deinit(self.allocator);
            self.processing_instructions.deinit(self.allocator);
            self.strings.deinit(self.allocator);
            if (comptime config.event_locations) self.locations.deinit(self.allocator);
            self.dtd_records.deinit(self.allocator);
            self.open_elements.deinit(self.allocator);
            self.last_children.deinit(self.allocator);
            self.open_child_counts.deinit(self.allocator);
            self.* = undefined;
        }

        /// Copies one public event into the partial document.
        /// After an error, later `consume` and `finish` calls return
        /// `InvalidEventSequence`; the caller must still call `deinit`.
        pub fn consume(self: *Self, event: reader.Event(config)) BuildError!void {
            if (self.document_ended or self.failed) return error.InvalidEventSequence;
            self.consumeEvent(event) catch |err| {
                self.failed = true;
                return err;
            };
        }

        fn consumeEvent(self: *Self, event: reader.Event(config)) BuildError!void {
            const payload = if (comptime config.event_locations) event.payload else event;
            const location = if (comptime config.event_locations) event.span.start else {};
            if (!self.fragment_complete) switch (payload) {
                .comment, .processing_instruction => {},
                else => return error.InvalidEventSequence,
            };
            if (comptime config.profile.dtdMode() == .rejected) {
                switch (payload) {
                    .document_start => |value| try self.startDocument(value, location),
                    .start_element => |value| try self.startElement(value, location),
                    .end_element => |value| try self.endElement(value),
                    .text => |value| try self.appendText(value, location),
                    .comment => |value| try self.appendComment(value, location),
                    .processing_instruction => |value| try self.appendPi(value, location),
                    .document_end => |value| try self.endDocument(value),
                }
            } else switch (payload) {
                .document_start => |value| try self.startDocument(value, location),
                .start_element => |value| try self.startElement(value, location),
                .end_element => |value| try self.endElement(value),
                .text => |value| try self.appendText(value, location),
                .comment => |value| try self.appendComment(value, location),
                .processing_instruction => |value| try self.appendPi(value, location),
                .document_end => |value| try self.endDocument(value),
                inline else => |value, tag| try self.consumeDtd(tag, value),
            }
        }

        /// Freezes a complete event stream and transfers the document storage.
        /// A successful transfer can occur only once.
        /// The caller must still deinitialize the builder to release construction scratch.
        pub fn finish(self: *Self) BuildError!ProfileDocumentFor(config) {
            if (self.failed or !self.document_ended or self.declaration == null or
                self.document_element == 0 or self.open_elements.items.len != 0)
                return error.InvalidEventSequence;
            const result: ProfileDocumentFor(config) = .{
                .allocator = self.allocator,
                .nodes = self.nodes,
                .elements = self.elements,
                .attributes = self.attributes,
                .namespaces = self.namespaces,
                .texts = self.texts,
                .comments = self.comments,
                .processing_instructions = self.processing_instructions,
                .strings = self.strings,
                .locations = if (config.event_locations) self.locations else {},
                .dtd_records = self.dtd_records,
                .declaration = self.declaration.?,
                .document_type = self.document_type,
                .document_element = self.document_element,
                .validation_status = self.validation_status,
            };
            self.nodes = .empty;
            self.elements = .empty;
            self.attributes = .empty;
            self.namespaces = .empty;
            self.texts = .empty;
            self.comments = .empty;
            self.processing_instructions = .empty;
            self.strings = .empty;
            if (comptime config.event_locations) self.locations = .empty;
            self.dtd_records = .empty;
            self.document_element = 0;
            return result;
        }

        fn startDocument(self: *Self, value: anytype, location: anytype) BuildError!void {
            if (self.declaration != null or self.nodes.items.len != 0) return error.InvalidEventSequence;
            self.declaration = .{
                .effective_version = value.effective_version,
                .declared_version = try self.copyOptional(value.declared_version),
                .source_encoding = value.source_encoding,
                .declared_encoding = try self.copyOptional(value.declared_encoding),
                .standalone = value.standalone,
                .standalone_declared = value.standalone_declared,
            };
            _ = try self.appendNode(.document, 0, location);
            try self.open_elements.append(self.allocator, 1);
            try self.last_children.append(self.allocator, 0);
            try self.open_child_counts.append(self.allocator, 0);
        }

        fn startElement(self: *Self, value: anytype, location: anytype) BuildError!void {
            if (self.declaration == null or self.open_elements.items.len == 0)
                return error.InvalidEventSequence;
            if (self.open_elements.items.len == 1 and self.document_element != 0)
                return error.InvalidEventSequence;
            try self.requireCount(
                self.attributes.items.len,
                value.attributes.len,
                self.options.limits.max_attributes,
            );
            const namespace_count = if (comptime config.profile.hasNamespaces())
                value.namespace_declarations.len
            else
                0;
            try self.requireCount(
                self.namespaces.items.len,
                namespace_count,
                self.options.limits.max_namespace_declarations,
            );

            const element_index = self.elements.items.len;
            if (element_index > std.math.maxInt(u32)) return error.TreeLimit;
            const attribute_start = self.attributes.items.len;
            const namespace_start = self.namespaces.items.len;
            const name = try self.copyName(value.name);
            for (value.attributes) |attribute| try self.appendAttribute(attribute);
            if (comptime config.profile.hasNamespaces()) {
                for (value.namespace_declarations) |declaration| {
                    try self.appendOwned(&self.namespaces, .{
                        .prefix = try self.copyOptional(declaration.prefix),
                        .namespace_uri = try self.copy(declaration.namespace_uri),
                    });
                    try self.checkCapacityLimit();
                }
            }
            if (comptime config.profile.hasNamespaces()) {
                try self.appendOwned(&self.elements, .{
                    .name = name,
                    .attribute_start = @intCast(attribute_start),
                    .attribute_count = @intCast(value.attributes.len),
                    .namespace_start = @intCast(namespace_start),
                    .namespace_count = @intCast(namespace_count),
                });
            } else {
                try self.appendOwned(&self.elements, .{
                    .name = name,
                    .attribute_start = @intCast(attribute_start),
                    .attribute_count = @intCast(value.attributes.len),
                });
            }
            try self.checkCapacityLimit();
            const node_index = try self.appendNode(.element, @intCast(element_index), location);
            if (self.document_element == 0) self.document_element = node_index;
            try self.open_elements.append(self.allocator, node_index);
            try self.last_children.append(self.allocator, 0);
            try self.open_child_counts.append(self.allocator, 0);
            self.clearFragment();
        }

        fn endElement(self: *Self, value: anytype) BuildError!void {
            if (self.open_elements.items.len <= 1) return error.InvalidEventSequence;
            const open = self.open_elements.getLast();
            const node = self.nodes.items[open - 1];
            if (node.kind != .element or !std.mem.eql(
                u8,
                self.poolBytes(self.elements.items[node.payload].name.raw),
                value.name.raw,
            )) return error.InvalidEventSequence;
            _ = self.open_elements.pop().?;
            _ = self.last_children.pop().?;
            _ = self.open_child_counts.pop().?;
            self.clearFragment();
        }

        fn appendText(self: *Self, value: anytype, location: anytype) BuildError!void {
            if (self.open_elements.items.len <= 1) return error.InvalidEventSequence;
            if (value.bytes.len > self.options.limits.max_coalesced_text_bytes)
                return error.TreeLimit;
            const ignorable = if (comptime config.profile.dtdMode() == .validating)
                value.ignorable_whitespace
            else
                false;
            const last = self.last_children.getLast();
            if (!self.text_boundary and last != 0) {
                const node = &self.nodes.items[last - 1];
                if (node.kind == .text) {
                    const record = &self.texts.items[node.payload];
                    const compatible_origin = !self.options.preserve_cdata_origin or
                        record.origin == value.origin;
                    if (compatible_origin and record.ignorable_whitespace == ignorable) {
                        const next_len = std.math.add(usize, record.value.len, value.bytes.len) catch
                            return error.TreeLimit;
                        if (next_len > self.options.limits.max_coalesced_text_bytes or
                            next_len > std.math.maxInt(u32)) return error.TreeLimit;
                        try self.appendToString(&record.value, value.bytes);
                        self.clearFragment();
                        return;
                    }
                }
            }
            const payload = self.texts.items.len;
            if (payload > std.math.maxInt(u32)) return error.TreeLimit;
            try self.appendOwned(&self.texts, .{
                .value = try self.copy(value.bytes),
                .origin = if (self.options.preserve_cdata_origin)
                    value.origin
                else
                    .character_data,
                .ignorable_whitespace = ignorable,
            });
            try self.checkCapacityLimit();
            _ = try self.appendNode(.text, @intCast(payload), location);
            self.clearFragment();
        }

        fn appendComment(self: *Self, value: anytype, location: anytype) BuildError!void {
            if (!self.fragment_complete) {
                const node = &self.nodes.items[self.fragment_node - 1];
                if (node.kind != .comment) return error.InvalidEventSequence;
                try self.appendToString(&self.comments.items[node.payload], value.bytes);
                self.fragment_complete = value.complete;
                if (value.complete) self.fragment_node = 0;
                return;
            }
            const payload = self.comments.items.len;
            if (payload > std.math.maxInt(u32)) return error.TreeLimit;
            try self.appendOwned(&self.comments, try self.copy(value.bytes));
            try self.checkCapacityLimit();
            const node_index = try self.appendNode(.comment, @intCast(payload), location);
            self.fragment_complete = value.complete;
            self.fragment_node = if (value.complete) 0 else node_index;
            self.text_boundary = true;
        }

        fn appendPi(self: *Self, value: anytype, location: anytype) BuildError!void {
            if (!self.fragment_complete) {
                const node = &self.nodes.items[self.fragment_node - 1];
                if (node.kind != .processing_instruction) return error.InvalidEventSequence;
                const record = &self.processing_instructions.items[node.payload];
                if (!std.mem.eql(u8, self.poolBytes(record.target), value.target))
                    return error.InvalidEventSequence;
                try self.appendToString(&record.data, value.data);
                self.fragment_complete = value.complete;
                if (value.complete) self.fragment_node = 0;
                return;
            }
            const payload = self.processing_instructions.items.len;
            if (payload > std.math.maxInt(u32)) return error.TreeLimit;
            const target = try self.copy(value.target);
            const data = try self.copy(value.data);
            try self.appendOwned(&self.processing_instructions, .{ .target = target, .data = data });
            try self.checkCapacityLimit();
            const node_index = try self.appendNode(.processing_instruction, @intCast(payload), location);
            self.fragment_complete = value.complete;
            self.fragment_node = if (value.complete) 0 else node_index;
            self.text_boundary = true;
        }

        fn endDocument(self: *Self, value: anytype) BuildError!void {
            if (self.declaration == null or self.open_elements.items.len != 1 or
                !self.fragment_complete or self.document_element == 0)
                return error.InvalidEventSequence;
            _ = self.open_elements.pop().?;
            _ = self.last_children.pop().?;
            _ = self.open_child_counts.pop().?;
            if (comptime config.profile.dtdMode() == .validating)
                self.validation_status = value.validation;
            self.document_ended = true;
        }

        fn consumeDtd(self: *Self, comptime tag: anytype, value: anytype) BuildError!void {
            const tag_name = @tagName(tag);
            if (comptime std.mem.eql(u8, tag_name, "document_type")) {
                if (self.document_type != null) return error.InvalidEventSequence;
                self.document_type = .{
                    .root_name = try self.copy(value.root_name),
                    .public_id = try self.copyOptional(value.public_id),
                    .system_id = try self.copyOptional(value.system_id),
                };
            } else if (comptime std.mem.eql(u8, tag_name, "notation_declaration")) {
                try self.appendDtd(.notation, value.name, value.public_id, value.system_id, null);
            } else if (comptime std.mem.eql(u8, tag_name, "unparsed_entity_declaration")) {
                try self.appendDtd(
                    .unparsed_entity,
                    value.name,
                    value.public_id,
                    value.system_id,
                    value.notation_name,
                );
            } else if (comptime std.mem.eql(u8, tag_name, "element_declaration")) {
                try self.appendDtd(.element, value.name, null, null, null);
            } else if (comptime std.mem.eql(u8, tag_name, "attribute_list_declaration")) {
                try self.appendDtd(.attribute_list, value.name, null, null, null);
            } else if (comptime std.mem.eql(u8, tag_name, "parsed_entity_declaration")) {
                try self.appendDtd(.parsed_entity, value.name, null, null, null);
            } else if (comptime std.mem.eql(u8, tag_name, "skipped_entity")) {
                try self.appendDtd(
                    .skipped_entity,
                    value.name,
                    value.public_id,
                    value.system_id,
                    null,
                );
                self.dtd_records.items[self.dtd_records.items.len - 1].skipped_entity_kind = value.kind;
                self.text_boundary = true;
            } else if (comptime std.mem.eql(u8, tag_name, "entity_start")) {
                try self.appendDtd(.entity_start, value.name, null, null, null);
                self.text_boundary = true;
            } else if (comptime std.mem.eql(u8, tag_name, "entity_end")) {
                try self.appendDtd(.entity_end, value.name, null, null, null);
                self.text_boundary = true;
            } else {
                @compileError("unhandled reader event");
            }
        }

        fn appendDtd(
            self: *Self,
            kind: DtdRecordKind,
            name: ?[]const u8,
            public_id: ?[]const u8,
            system_id: ?[]const u8,
            notation_name: ?[]const u8,
        ) BuildError!void {
            if (self.dtd_records.items.len >= std.math.maxInt(u32)) return error.TreeLimit;
            try self.appendOwned(&self.dtd_records, .{
                .kind = kind,
                .name = try self.copyOptional(name),
                .public_id = try self.copyOptional(public_id),
                .system_id = try self.copyOptional(system_id),
                .notation_name = try self.copyOptional(notation_name),
            });
            try self.checkCapacityLimit();
        }

        fn appendAttribute(self: *Self, value: anytype) BuildError!void {
            const declared_type = if (comptime config.profile.dtdMode() == .rejected)
                null
            else
                value.declared_type;
            if (comptime config.profile.dtdMode() == .rejected) {
                try self.appendOwned(&self.attributes, .{
                    .name = try self.copyName(value.name),
                    .value = try self.copy(value.value),
                });
            } else {
                try self.appendOwned(&self.attributes, .{
                    .name = try self.copyName(value.name),
                    .value = try self.copy(value.value),
                    .specified = value.specified,
                    .declared_type = if (declared_type) |kind| @intFromEnum(kind) else 0,
                    .has_declared_type = declared_type != null,
                });
            }
            try self.checkCapacityLimit();
        }

        fn appendNode(
            self: *Self,
            kind: NodeKind,
            payload: u32,
            location: anytype,
        ) BuildError!NodeIndex {
            if (self.nodes.items.len >= self.options.limits.max_nodes or
                self.nodes.items.len >= std.math.maxInt(u32)) return error.TreeLimit;
            const parent = if (self.open_elements.items.len == 0)
                0
            else
                self.open_elements.getLast();
            if (parent != 0) {
                const child_count = self.open_child_counts.getLast();
                if (self.nodes.items[parent - 1].kind == .element and
                    (child_count >= self.options.limits.max_children_per_element or
                        child_count == std.math.maxInt(u32))) return error.TreeLimit;
            }
            try self.appendOwned(&self.nodes, .{ .kind = kind, .payload = payload, .parent = parent });
            errdefer _ = self.nodes.pop();
            if (comptime config.event_locations) {
                try self.appendOwned(&self.locations, location);
            }
            const index: NodeIndex = @intCast(self.nodes.items.len);
            if (parent != 0) {
                const parent_node = &self.nodes.items[parent - 1];
                const last = self.last_children.getLast();
                if (last == 0) parent_node.first_child = index else self.nodes.items[last - 1].next_sibling = index;
                self.open_child_counts.items[self.open_child_counts.items.len - 1] += 1;
                self.last_children.items[self.last_children.items.len - 1] = index;
            }
            try self.checkCapacityLimit();
            self.text_boundary = false;
            return index;
        }

        fn copyName(self: *Self, value: anytype) BuildError!StoredName(config) {
            if (comptime config.profile.hasNamespaces()) {
                return .{
                    .raw = try self.copy(value.raw),
                    .prefix = try self.copyOptional(value.prefix),
                    .local = try self.copy(value.local),
                    .namespace_uri = try self.copyOptional(value.namespace_uri),
                };
            }
            const raw = try self.copy(value.raw);
            return .{ .raw = raw };
        }

        fn copy(self: *Self, bytes: []const u8) BuildError!StringRef {
            const end = std.math.add(usize, self.strings.items.len, bytes.len) catch
                return error.TreeLimit;
            if (end > self.options.limits.max_string_bytes or end >= std.math.maxInt(u32))
                return error.TreeLimit;
            const offset = self.strings.items.len;
            try self.reserveOwned(&self.strings, bytes.len);
            self.strings.appendSliceAssumeCapacity(bytes);
            try self.checkCapacityLimit();
            return .{ .offset = @intCast(offset), .len = @intCast(bytes.len) };
        }

        fn copyOptional(self: *Self, value: ?[]const u8) BuildError!StringRef {
            return if (value) |bytes| try self.copy(bytes) else .{};
        }

        fn appendToString(self: *Self, value: *StringRef, bytes: []const u8) BuildError!void {
            if (value.offset + value.len != self.strings.items.len) return error.InvalidEventSequence;
            const next_len = std.math.add(usize, value.len, bytes.len) catch return error.TreeLimit;
            if (next_len > std.math.maxInt(u32)) return error.TreeLimit;
            _ = try self.copy(bytes);
            value.len = @intCast(next_len);
        }

        fn poolBytes(self: *const Self, value: StringRef) []const u8 {
            return self.strings.items[value.offset..][0..value.len];
        }

        fn requireCount(self: *Self, current: usize, added: usize, maximum: usize) BuildError!void {
            _ = self;
            const total = std.math.add(usize, current, added) catch return error.TreeLimit;
            if (total > maximum or total > std.math.maxInt(u32)) return error.TreeLimit;
        }

        fn appendOwned(
            self: *Self,
            list: anytype,
            value: std.meta.Elem(@TypeOf(list.items)),
        ) BuildError!void {
            try self.reserveOwned(list, 1);
            list.appendAssumeCapacity(value);
        }

        fn reserveOwned(self: *Self, list: anytype, additional: usize) BuildError!void {
            const required = std.math.add(usize, list.items.len, additional) catch
                return error.TreeLimit;
            if (required <= list.capacity) return;
            var capacity = list.capacity;
            while (capacity < required) {
                const increment = capacity / 2 + 8;
                capacity = std.math.add(usize, capacity, increment) catch return error.TreeLimit;
            }
            const item_size = @sizeOf(@TypeOf(list.items[0]));
            var projected = self.ownedCapacity() catch return error.TreeLimit;
            const old_bytes = std.math.mul(usize, list.capacity, item_size) catch
                return error.TreeLimit;
            const new_bytes = std.math.mul(usize, capacity, item_size) catch
                return error.TreeLimit;
            projected -= old_bytes;
            projected = std.math.add(usize, projected, new_bytes) catch return error.TreeLimit;
            if (projected > self.options.limits.max_tree_bytes) return error.TreeLimit;
            list.ensureTotalCapacityPrecise(self.allocator, capacity) catch return error.OutOfMemory;
        }

        fn ownedCapacity(self: *const Self) !usize {
            var total = try capacityBytes(
                config,
                self.nodes.capacity,
                self.attributes.capacity,
                self.namespaces.capacity,
                self.strings.capacity,
            );
            inline for (.{
                .{ self.elements.capacity, @sizeOf(ElementRecord(config)) },
                .{ self.texts.capacity, @sizeOf(TextRecord) },
                .{ self.comments.capacity, @sizeOf(StringRef) },
                .{ self.processing_instructions.capacity, @sizeOf(PiRecord) },
                .{ self.dtd_records.capacity, @sizeOf(StoredDtdRecord) },
            }) |entry| try addCapacity(&total, entry[0], entry[1]);
            if (comptime config.event_locations) try addCapacity(
                &total,
                self.locations.capacity,
                @sizeOf(reader.Location(config)),
            );
            return total;
        }

        fn checkCapacityLimit(self: *const Self) BuildError!void {
            const total = self.ownedCapacity() catch return error.TreeLimit;
            if (total > self.options.limits.max_tree_bytes) return error.TreeLimit;
        }

        fn clearFragment(self: *Self) void {
            self.fragment_node = 0;
            self.fragment_complete = true;
        }
    };
}

/// Parses one complete source into an owned document.
///
/// The source, Reader option borrows, and callback contexts need to remain valid
/// only until this call returns. The returned document owns its retained XML.
/// That ownership transfers to the caller and must be released with `deinit`.
pub fn parseDocument(
    allocator: std.mem.Allocator,
    source: reader.NormalSource,
    options: DocumentOptions,
) ParseDocumentError!Document {
    var normal_reader = try reader.NormalReader.init(allocator, source, options.reader);
    defer normal_reader.deinit();

    var builder = DocumentBuilder.init(allocator, options) catch |err| {
        return mapBuildError(err);
    };
    defer builder.deinit();

    while (try normal_reader.next()) |event| {
        builder.consume(event) catch |err| return mapBuildError(err);
    }
    return builder.finish(&normal_reader) catch |err| return mapBuildError(err);
}

const DocumentBuilder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    options: DocumentOptions,
    nodes: std.ArrayList(Node) = .empty,
    elements: std.ArrayList(DocumentElementRecord) = .empty,
    attributes: std.ArrayList(DocumentAttributeRecord) = .empty,
    namespaces: std.ArrayList(NamespaceRecord) = .empty,
    texts: std.ArrayList(StringRef) = .empty,
    text_origins: std.ArrayList(reader.TextOrigin) = .empty,
    comments: std.ArrayList(StringRef) = .empty,
    processing_instructions: std.ArrayList(PiRecord) = .empty,
    strings: std.ArrayList(u8) = .empty,
    dtd_finding_inclusions: std.ArrayList(reader.NormalLocation) = .empty,
    open_elements: std.ArrayList(NodeIndex) = .empty,
    last_children: std.ArrayList(NodeIndex) = .empty,
    open_child_counts: std.ArrayList(u32) = .empty,
    start_result: ?StoredDocumentStart = null,
    document_type: ?StoredDocumentType = null,
    document_element: NodeIndex = 0,
    end_result: ?reader.NormalDocumentEnd = null,
    document_ended: bool = false,
    failed: bool = false,
    fragment_node: NodeIndex = 0,
    fragment_complete: bool = true,
    text_boundary: bool = false,

    fn init(allocator: std.mem.Allocator, options: DocumentOptions) BuildError!Self {
        if (!options.limits.valid()) return error.InvalidOptions;
        return .{ .allocator = allocator, .options = options };
    }

    fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
        self.elements.deinit(self.allocator);
        self.attributes.deinit(self.allocator);
        self.namespaces.deinit(self.allocator);
        self.texts.deinit(self.allocator);
        self.text_origins.deinit(self.allocator);
        self.comments.deinit(self.allocator);
        self.processing_instructions.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.dtd_finding_inclusions.deinit(self.allocator);
        self.open_elements.deinit(self.allocator);
        self.last_children.deinit(self.allocator);
        self.open_child_counts.deinit(self.allocator);
        self.* = undefined;
    }

    fn consume(self: *Self, event: reader.NormalEvent) BuildError!void {
        if (self.document_ended or self.failed) return error.InvalidEventSequence;
        self.consumeEvent(event) catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn consumeEvent(self: *Self, event: reader.NormalEvent) BuildError!void {
        if (!self.fragment_complete) switch (event.data) {
            .comment, .processing_instruction => {},
            else => return error.InvalidEventSequence,
        };
        switch (event.data) {
            .document_start => |value| try self.startDocument(value),
            .document_type => |value| try self.setDocumentType(value),
            .start_element => |value| try self.startElement(value),
            .end_element => |value| try self.endElement(value),
            .text => |value| try self.appendText(value),
            .comment => |value| {
                if (!self.options.retain_comments) return;
                try self.appendComment(value);
            },
            .processing_instruction => |value| {
                if (!self.options.retain_processing_instructions) return;
                try self.appendPi(value);
            },
            .skipped_external_source => self.text_boundary = true,
            .document_end => |value| try self.endDocument(value),
        }
    }

    fn startDocument(self: *Self, value: reader.NormalDocumentStart) BuildError!void {
        if (self.start_result != null or self.nodes.items.len != 0)
            return error.InvalidEventSequence;
        const declaration = value.declaration;
        self.start_result = .{
            .effective_version = value.effective_version,
            .source_encoding = value.source_encoding,
            .declaration_present = declaration != null,
            .declared_version = if (declaration) |item| item.version else value.effective_version,
            .declared_encoding = try self.copyOptional(if (declaration) |item|
                item.encoding
            else
                null),
            .standalone = if (declaration) |item| item.standalone orelse false else false,
            .standalone_declared = if (declaration) |item| item.standalone != null else false,
        };
        _ = try self.appendNode(.document, 0);
        try self.open_elements.append(self.allocator, 1);
        try self.last_children.append(self.allocator, 0);
        try self.open_child_counts.append(self.allocator, 0);
    }

    fn setDocumentType(self: *Self, value: reader.NormalDocumentType) BuildError!void {
        if (self.start_result == null or self.document_type != null or self.document_element != 0)
            return error.InvalidEventSequence;
        self.document_type = .{
            .root_name = try self.copy(value.root_name),
            .public_id = try self.copyOptional(value.public_id),
            .system_id = try self.copyOptional(value.system_id),
        };
    }

    fn startElement(self: *Self, value: reader.NormalStartElement) BuildError!void {
        if (self.start_result == null or self.open_elements.items.len == 0)
            return error.InvalidEventSequence;
        if (self.open_elements.items.len == 1 and self.document_element != 0)
            return error.InvalidEventSequence;
        try self.requireCount(
            self.attributes.items.len,
            value.attributes.len,
            self.options.limits.max_attributes,
        );
        try self.requireCount(
            self.namespaces.items.len,
            value.namespace_declarations.len,
            self.options.limits.max_namespace_declarations,
        );

        const element_index = self.elements.items.len;
        if (element_index > std.math.maxInt(u32)) return error.TreeLimit;
        const attribute_start = self.attributes.items.len;
        const namespace_start = self.namespaces.items.len;
        const name = try self.copyName(value.name);
        try self.reserveOwned(&self.attributes, value.attributes.len);
        try self.reserveOwned(&self.namespaces, value.namespace_declarations.len);
        for (value.attributes) |attribute| try self.appendAttribute(attribute);
        for (value.namespace_declarations) |declaration| {
            try self.appendOwned(&self.namespaces, .{
                .prefix = try self.copyOptional(declaration.prefix),
                .namespace_uri = try self.copy(declaration.namespace_uri),
            });
        }
        try self.appendOwned(&self.elements, .{
            .name = name,
            .attribute_start = @intCast(attribute_start),
            .attribute_count = @intCast(value.attributes.len),
            .namespace_start = @intCast(namespace_start),
            .namespace_count = @intCast(value.namespace_declarations.len),
        });
        const node_index = try self.appendNode(.element, @intCast(element_index));
        if (self.document_element == 0) self.document_element = node_index;
        try self.open_elements.append(self.allocator, node_index);
        try self.last_children.append(self.allocator, 0);
        try self.open_child_counts.append(self.allocator, 0);
        self.clearFragment();
    }

    fn endElement(self: *Self, value: reader.NormalEndElement) BuildError!void {
        if (self.open_elements.items.len <= 1) return error.InvalidEventSequence;
        const open = self.open_elements.getLast();
        const node = self.nodes.items[open - 1];
        if (node.kind != .element or !std.mem.eql(
            u8,
            self.poolBytes(self.elements.items[node.payload].name.raw),
            value.name.raw,
        )) return error.InvalidEventSequence;
        _ = self.open_elements.pop().?;
        _ = self.last_children.pop().?;
        _ = self.open_child_counts.pop().?;
        self.clearFragment();
    }

    fn appendText(self: *Self, value: reader.NormalText) BuildError!void {
        if (self.open_elements.items.len <= 1) return error.InvalidEventSequence;
        if (value.bytes.len == 0) return;
        if (value.bytes.len > self.options.limits.max_coalesced_text_bytes)
            return error.TreeLimit;
        const last = self.last_children.getLast();
        if (!self.text_boundary and last != 0) {
            const node = &self.nodes.items[last - 1];
            if (node.kind == .text) {
                const compatible_origin = !self.options.retain_text_origin or
                    self.text_origins.items[node.payload] == value.origin;
                if (compatible_origin) {
                    const record = &self.texts.items[node.payload];
                    const next_len = std.math.add(usize, record.len, value.bytes.len) catch
                        return error.TreeLimit;
                    if (next_len > self.options.limits.max_coalesced_text_bytes or
                        next_len > std.math.maxInt(u32)) return error.TreeLimit;
                    try self.appendToString(record, value.bytes);
                    self.clearFragment();
                    return;
                }
            }
        }
        const payload = self.texts.items.len;
        if (payload > std.math.maxInt(u32)) return error.TreeLimit;
        try self.appendOwned(&self.texts, try self.copy(value.bytes));
        if (self.options.retain_text_origin) {
            try self.appendOwned(&self.text_origins, value.origin);
        }
        _ = try self.appendNode(.text, @intCast(payload));
        self.clearFragment();
    }

    fn appendComment(self: *Self, value: reader.NormalComment) BuildError!void {
        if (!self.fragment_complete) {
            const node = &self.nodes.items[self.fragment_node - 1];
            if (node.kind != .comment) return error.InvalidEventSequence;
            try self.appendToString(&self.comments.items[node.payload], value.bytes);
            self.fragment_complete = value.final_fragment;
            if (value.final_fragment) self.fragment_node = 0;
            return;
        }
        const payload = self.comments.items.len;
        if (payload > std.math.maxInt(u32)) return error.TreeLimit;
        try self.appendOwned(&self.comments, try self.copy(value.bytes));
        const node_index = try self.appendNode(.comment, @intCast(payload));
        self.fragment_complete = value.final_fragment;
        self.fragment_node = if (value.final_fragment) 0 else node_index;
        self.text_boundary = true;
    }

    fn appendPi(self: *Self, value: reader.NormalProcessingInstruction) BuildError!void {
        if (!self.fragment_complete) {
            const node = &self.nodes.items[self.fragment_node - 1];
            if (node.kind != .processing_instruction) return error.InvalidEventSequence;
            const record = &self.processing_instructions.items[node.payload];
            if (!std.mem.eql(u8, self.poolBytes(record.target), value.target))
                return error.InvalidEventSequence;
            try self.appendToString(&record.data, value.data);
            self.fragment_complete = value.final_fragment;
            if (value.final_fragment) self.fragment_node = 0;
            return;
        }
        const payload = self.processing_instructions.items.len;
        if (payload > std.math.maxInt(u32)) return error.TreeLimit;
        const target = try self.copy(value.target);
        const data = try self.copy(value.data);
        try self.appendOwned(&self.processing_instructions, .{ .target = target, .data = data });
        const node_index = try self.appendNode(.processing_instruction, @intCast(payload));
        self.fragment_complete = value.final_fragment;
        self.fragment_node = if (value.final_fragment) 0 else node_index;
        self.text_boundary = true;
    }

    fn endDocument(self: *Self, value: reader.NormalDocumentEnd) BuildError!void {
        if (self.start_result == null or self.open_elements.items.len != 1 or
            !self.fragment_complete or self.document_element == 0)
            return error.InvalidEventSequence;
        _ = self.open_elements.pop().?;
        _ = self.last_children.pop().?;
        _ = self.open_child_counts.pop().?;
        self.end_result = value;
        self.document_ended = true;
    }

    fn finish(self: *Self, normal_reader: *const reader.NormalReader) BuildError!Document {
        if (self.failed or !self.document_ended or self.start_result == null or
            self.document_element == 0 or self.open_elements.items.len != 0)
            return error.InvalidEventSequence;
        const finding = normal_reader.firstDtdFinding();
        if (finding) |value| {
            if (value.inclusion_trace.len != 0) {
                try self.reserveOwned(&self.dtd_finding_inclusions, value.inclusion_trace.len);
                self.dtd_finding_inclusions.appendSliceAssumeCapacity(value.inclusion_trace);
            }
        }
        const result: Document = .{
            .allocator = self.allocator,
            .nodes = self.nodes,
            .elements = self.elements,
            .attributes_storage = self.attributes,
            .namespace_storage = self.namespaces,
            .texts = self.texts,
            .text_origins = self.text_origins,
            .comments = self.comments,
            .processing_instructions = self.processing_instructions,
            .strings = self.strings,
            .dtd_finding_inclusions = self.dtd_finding_inclusions,
            .start_result = self.start_result.?,
            .document_type = self.document_type,
            .document_element = self.document_element,
            .end_result = self.end_result.?,
            .first_dtd_finding = if (finding) |value| .{
                .code = value.code,
                .primary = value.primary,
                .related = value.related,
            } else null,
            .normalization_finding = normal_reader.normalizationFinding(),
            .namespaces_processed = self.options.reader.namespaces == .process,
            .text_origin_retained = self.options.retain_text_origin,
        };
        self.nodes = .empty;
        self.elements = .empty;
        self.attributes = .empty;
        self.namespaces = .empty;
        self.texts = .empty;
        self.text_origins = .empty;
        self.comments = .empty;
        self.processing_instructions = .empty;
        self.strings = .empty;
        self.dtd_finding_inclusions = .empty;
        self.document_element = 0;
        return result;
    }

    fn appendAttribute(self: *Self, value: reader.NormalAttribute) BuildError!void {
        try self.appendOwned(&self.attributes, .{
            .name = try self.copyName(value.name),
            .value = try self.copy(value.value),
            .specified = value.specified,
            .declared_type = if (value.declared_type) |kind| @intFromEnum(kind) else 0,
            .has_declared_type = value.declared_type != null,
        });
    }

    fn appendNode(self: *Self, kind: NodeKind, payload: u32) BuildError!NodeIndex {
        if (self.nodes.items.len >= self.options.limits.max_nodes or
            self.nodes.items.len >= std.math.maxInt(u32)) return error.TreeLimit;
        const parent = if (self.open_elements.items.len == 0)
            0
        else
            self.open_elements.getLast();
        if (parent != 0) {
            const child_count = self.open_child_counts.getLast();
            if (self.nodes.items[parent - 1].kind == .element and
                (child_count >= self.options.limits.max_children_per_element or
                    child_count == std.math.maxInt(u32))) return error.TreeLimit;
        }
        try self.appendOwned(&self.nodes, .{ .kind = kind, .payload = payload, .parent = parent });
        const index: NodeIndex = @intCast(self.nodes.items.len);
        if (parent != 0) {
            const parent_node = &self.nodes.items[parent - 1];
            const last = self.last_children.getLast();
            if (last == 0) {
                parent_node.first_child = index;
            } else {
                self.nodes.items[last - 1].next_sibling = index;
            }
            self.open_child_counts.items[self.open_child_counts.items.len - 1] += 1;
            self.last_children.items[self.last_children.items.len - 1] = index;
        }
        self.text_boundary = false;
        return index;
    }

    fn copyName(self: *Self, value: reader.NormalName) BuildError!DocumentNameRecord {
        var result: DocumentNameRecord = .{ .raw = try self.copy(value.raw) };
        if (value.expanded) |expanded| {
            result.prefix = try self.copyOptional(expanded.prefix);
            result.local = try self.copy(expanded.local);
            result.namespace_uri = try self.copyOptional(expanded.namespace_uri);
        }
        return result;
    }

    fn copy(self: *Self, bytes: []const u8) BuildError!StringRef {
        const end = std.math.add(usize, self.strings.items.len, bytes.len) catch
            return error.TreeLimit;
        if (end > self.options.limits.max_string_bytes or end >= std.math.maxInt(u32))
            return error.TreeLimit;
        const offset = self.strings.items.len;
        try self.reserveOwned(&self.strings, bytes.len);
        self.strings.appendSliceAssumeCapacity(bytes);
        return .{ .offset = @intCast(offset), .len = @intCast(bytes.len) };
    }

    fn copyOptional(self: *Self, value: ?[]const u8) BuildError!StringRef {
        return if (value) |bytes| try self.copy(bytes) else .{};
    }

    fn appendToString(self: *Self, value: *StringRef, bytes: []const u8) BuildError!void {
        if (value.offset + value.len != self.strings.items.len)
            return error.InvalidEventSequence;
        const next_len = std.math.add(usize, value.len, bytes.len) catch return error.TreeLimit;
        if (next_len > std.math.maxInt(u32)) return error.TreeLimit;
        _ = try self.copy(bytes);
        value.len = @intCast(next_len);
    }

    fn poolBytes(self: *const Self, value: StringRef) []const u8 {
        return self.strings.items[value.offset..][0..value.len];
    }

    fn requireCount(self: *Self, current: usize, added: usize, maximum: usize) BuildError!void {
        _ = self;
        const total = std.math.add(usize, current, added) catch return error.TreeLimit;
        if (total > maximum or total > std.math.maxInt(u32)) return error.TreeLimit;
    }

    fn appendOwned(
        self: *Self,
        list: anytype,
        value: std.meta.Elem(@TypeOf(list.items)),
    ) BuildError!void {
        try self.reserveOwned(list, 1);
        list.appendAssumeCapacity(value);
    }

    fn reserveOwned(self: *Self, list: anytype, additional: usize) BuildError!void {
        const required = std.math.add(usize, list.items.len, additional) catch
            return error.TreeLimit;
        if (required <= list.capacity) return;
        var capacity = list.capacity;
        while (capacity < required) {
            const increment = capacity / 2 + 8;
            capacity = std.math.add(usize, capacity, increment) catch return error.TreeLimit;
        }
        const item_size = @sizeOf(std.meta.Elem(@TypeOf(list.items)));
        var projected = self.ownedCapacity() catch return error.TreeLimit;
        const old_bytes = std.math.mul(usize, list.capacity, item_size) catch
            return error.TreeLimit;
        const new_bytes = std.math.mul(usize, capacity, item_size) catch
            return error.TreeLimit;
        projected -= old_bytes;
        projected = std.math.add(usize, projected, new_bytes) catch return error.TreeLimit;
        if (projected > self.options.limits.max_retained_bytes) return error.TreeLimit;
        list.ensureTotalCapacityPrecise(self.allocator, capacity) catch return error.OutOfMemory;
    }

    fn ownedCapacity(self: *const Self) !usize {
        var total = self.strings.capacity;
        inline for (.{
            .{ self.nodes.capacity, @sizeOf(Node) },
            .{ self.elements.capacity, @sizeOf(DocumentElementRecord) },
            .{ self.attributes.capacity, @sizeOf(DocumentAttributeRecord) },
            .{ self.namespaces.capacity, @sizeOf(NamespaceRecord) },
            .{ self.texts.capacity, @sizeOf(StringRef) },
            .{ self.text_origins.capacity, @sizeOf(reader.TextOrigin) },
            .{ self.comments.capacity, @sizeOf(StringRef) },
            .{ self.processing_instructions.capacity, @sizeOf(PiRecord) },
            .{ self.dtd_finding_inclusions.capacity, @sizeOf(reader.NormalLocation) },
        }) |entry| try addCapacity(&total, entry[0], entry[1]);
        return total;
    }

    fn clearFragment(self: *Self) void {
        self.fragment_node = 0;
        self.fragment_complete = true;
    }
};

fn mapBuildError(err: BuildError) ParseDocumentError {
    return switch (err) {
        error.TreeLimit => error.DocumentLimit,
        error.InvalidOptions => error.InvalidOptions,
        error.InvalidEventSequence => error.InvalidEventSequence,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn capacityBytes(
    comptime config: reader.Config,
    nodes: usize,
    attributes: usize,
    namespaces: usize,
    strings: usize,
) !usize {
    var total = strings;
    try addCapacity(&total, nodes, @sizeOf(Node));
    try addCapacity(&total, attributes, @sizeOf(AttributeRecord(config)));
    try addCapacity(&total, namespaces, @sizeOf(NamespaceRecord));
    return total;
}

fn addCapacity(total: *usize, count: usize, item_size: usize) !void {
    const bytes = std.math.mul(usize, count, item_size) catch return error.Overflow;
    total.* = std.math.add(usize, total.*, bytes) catch return error.Overflow;
}

/// Builds a document from any pull reader exposing `next()` with the matching event type.
pub fn buildProfileFromPull(
    comptime config: reader.Config,
    allocator: std.mem.Allocator,
    options: Options,
    pull: anytype,
) (BuildError || reader.ReadError)!ProfileDocumentFor(config) {
    var builder = try ProfileBuilderFor(config).init(allocator, options);
    defer builder.deinit();
    while (true) {
        switch (try pull.next()) {
            .event => |event| try builder.consume(event),
            .need_input => return error.InvalidEventSequence,
            .done => return builder.finish(),
        }
    }
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
