//! Compiles DTD declarations and tracks document-wide validity state.

const std = @import("std");
const dtd = @import("dtd.zig");

pub const Limits = struct {
    max_content_positions: usize = 4096,
    max_content_states: usize = 16 * 1024,
    max_content_transitions: usize = 64 * 1024,
    max_compilation_work: usize = 8 * 1024 * 1024,
    max_ids: usize = 1024 * 1024,
    max_idrefs: usize = 1024 * 1024,
    max_id_bytes: usize = 8 * 1024 * 1024,
    max_comparison_work: usize = 16 * 1024 * 1024,
    max_errors: usize = 1024,

    pub fn validate(self: Limits) bool {
        return self.max_content_positions > 0 and
            self.max_content_positions <= (std.math.maxInt(u32) - 2) / 4 and
            self.max_content_states > 0 and
            self.max_content_states <= std.math.maxInt(u32) and
            self.max_content_transitions > 0 and
            self.max_content_transitions <= std.math.maxInt(u32) and
            self.max_compilation_work > 0 and
            self.max_ids > 0 and
            self.max_idrefs > 0 and
            self.max_id_bytes > 0 and
            self.max_comparison_work > 0 and
            self.max_errors > 0;
    }
};

pub const Error = error{
    OutOfMemory,
    ContentPositionLimit,
    ContentStateLimit,
    ContentTransitionLimit,
    CompilationWorkLimit,
    IdLimit,
    IdrefLimit,
    IdentityBytesLimit,
    ComparisonWorkLimit,
};

pub const IssueCode = enum {
    missing_doctype,
    root_name_mismatch,
    undeclared_element,
    duplicate_element_declaration,
    nondeterministic_content_model,
    improper_parameter_entity_nesting,
    duplicate_mixed_content_name,
    invalid_element_content,
    undeclared_attribute,
    undeclared_entity,
    required_attribute_missing,
    fixed_attribute_mismatch,
    invalid_attribute_value,
    duplicate_id,
    unresolved_idref,
    multiple_id_attributes,
    invalid_id_default,
    multiple_notation_attributes,
    notation_on_empty_element,
    duplicate_enumeration_token,
    undeclared_notation,
    duplicate_notation_declaration,
    invalid_xml_space_declaration,
    standalone_external_default,
    standalone_external_normalization,
    standalone_external_whitespace,
};

pub const SourceLocation = struct {
    source_id: u32 = 0,
    byte_offset: u64 = 0,
    line: u64 = 1,
    byte_column: u64 = 1,
};

pub const Issue = struct {
    code: IssueCode,
    declaration: ?dtd.DeclarationLocation = null,
    related: ?dtd.DeclarationLocation = null,
    occurrence: ?SourceLocation = null,
};

const ModelKind = enum { empty, any, mixed, children };

const Model = struct {
    element_index: usize,
    kind: ModelKind,
    position_count: usize = 0,
    start_state: u32 = 0,
    state_start: usize = 0,
    state_len: usize = 0,
    mixed_start: usize = 0,
    mixed_len: usize = 0,
};

const DfaState = struct {
    item_start: usize,
    item_len: usize,
    transition_start: u32 = 0,
    accepting: bool,
};

const Transition = struct {
    name: dtd.StoredString,
    target: u32,
};

const NfaState = struct {
    epsilon_a: ?u32 = null,
    epsilon_b: ?u32 = null,
    name: ?dtd.StoredString = null,
    target: u32 = 0,
};

const Fragment = struct { start: u32, end: u32 };

const Postfix = union(enum) {
    name: dtd.StoredString,
    sequence,
    choice,
    optional,
    zero_or_more,
    one_or_more,
};

const Group = struct {
    separator: u8 = 0,
    terms: usize = 0,
};

const IdRecord = struct {
    offset: usize,
    len: usize,
    location: SourceLocation,
    hash: u64,
};

pub const Frame = struct {
    model_index: ?u32 = null,
    state: u32 = 0,
    invalid_content: bool = false,
    declared_external: bool = false,
};

pub const BeginElement = struct {
    frame: Frame,
    issue: ?Issue = null,
};

pub const State = struct {
    models: std.ArrayList(Model) = .empty,
    dfa_states: std.ArrayList(DfaState) = .empty,
    dfa_items: std.ArrayList(u32) = .empty,
    transitions: std.ArrayList(Transition) = .empty,
    mixed_names: std.ArrayList(dtd.StoredString) = .empty,
    issues: std.ArrayList(Issue) = .empty,
    id_bytes: std.ArrayList(u8) = .empty,
    ids: std.ArrayList(IdRecord) = .empty,
    id_slots: std.ArrayList(u32) = .empty,
    idrefs: std.ArrayList(IdRecord) = .empty,
    compilation_work: usize = 0,
    comparison_work: usize = 0,
    root_seen: bool = false,
    issues_truncated: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.models.deinit(allocator);
        self.dfa_states.deinit(allocator);
        self.dfa_items.deinit(allocator);
        self.transitions.deinit(allocator);
        self.mixed_names.deinit(allocator);
        self.issues.deinit(allocator);
        self.id_bytes.deinit(allocator);
        self.ids.deinit(allocator);
        self.id_slots.deinit(allocator);
        self.idrefs.deinit(allocator);
        self.* = .{};
    }

    pub fn clearRetainingCapacity(self: *State) void {
        self.models.clearRetainingCapacity();
        self.dfa_states.clearRetainingCapacity();
        self.dfa_items.clearRetainingCapacity();
        self.transitions.clearRetainingCapacity();
        self.mixed_names.clearRetainingCapacity();
        self.issues.clearRetainingCapacity();
        self.id_bytes.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        @memset(self.id_slots.items, 0);
        self.idrefs.clearRetainingCapacity();
        self.compilation_work = 0;
        self.comparison_work = 0;
        self.root_seen = false;
        self.issues_truncated = false;
    }

    pub fn capacity(self: *const State) usize {
        return self.contentModelCapacity() +| self.identityCapacity() +|
            self.issues.capacity *| @sizeOf(Issue);
    }

    pub fn contentModelCapacity(self: *const State) usize {
        return self.models.capacity *| @sizeOf(Model) +|
            self.dfa_states.capacity *| @sizeOf(DfaState) +|
            self.dfa_items.capacity *| @sizeOf(u32) +|
            self.transitions.capacity *| @sizeOf(Transition) +|
            self.mixed_names.capacity *| @sizeOf(dtd.StoredString);
    }

    pub fn identityCapacity(self: *const State) usize {
        return self.id_bytes.capacity +|
            (self.ids.capacity +| self.idrefs.capacity) *| @sizeOf(IdRecord) +|
            self.id_slots.capacity *| @sizeOf(u32);
    }

    pub fn idCount(self: *const State) usize {
        return self.ids.items.len;
    }

    pub fn idrefCount(self: *const State) usize {
        return self.idrefs.items.len;
    }

    pub fn identityBytes(self: *const State) usize {
        return self.id_bytes.items.len;
    }

    pub fn idCapacity(self: *const State) usize {
        return self.ids.capacity *| @sizeOf(IdRecord);
    }

    pub fn idrefCapacity(self: *const State) usize {
        return self.idrefs.capacity *| @sizeOf(IdRecord);
    }

    pub fn idIndexCapacity(self: *const State) usize {
        return self.id_slots.capacity *| @sizeOf(u32);
    }

    pub fn prepare(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        declarations: *const dtd.State,
    ) Error!void {
        if (declarations.elements.items.len > std.math.maxInt(u32)) {
            return error.ContentStateLimit;
        }
        self.models.clearRetainingCapacity();
        self.dfa_states.clearRetainingCapacity();
        self.dfa_items.clearRetainingCapacity();
        self.transitions.clearRetainingCapacity();
        self.mixed_names.clearRetainingCapacity();
        self.issues.clearRetainingCapacity();
        self.compilation_work = 0;
        self.issues_truncated = false;

        for (declarations.elements.items, 0..) |element, element_index| {
            if (self.firstElement(declarations, element.name, element_index)) |first| {
                try self.addIssue(allocator, limits, .{
                    .code = .duplicate_element_declaration,
                    .declaration = element.location,
                    .related = declarations.elements.items[first].location,
                });
                continue;
            }
            var model: Model = .{
                .element_index = element_index,
                .kind = switch (element.content_kind) {
                    .empty => .empty,
                    .any => .any,
                    .mixed => .mixed,
                    .children => .children,
                },
            };
            if (model.kind == .children) {
                const deterministic = try self.compileModel(
                    allocator,
                    limits,
                    declarations,
                    element.content_spec.?,
                    &model,
                );
                if (!deterministic) {
                    try self.addIssue(allocator, limits, .{
                        .code = .nondeterministic_content_model,
                        .declaration = element.location,
                    });
                    model.kind = .any;
                }
            } else if (model.kind == .mixed) {
                if (try self.compileMixed(
                    allocator,
                    limits,
                    declarations,
                    element.content_spec.?,
                    &model,
                )) {
                    try self.addIssue(allocator, limits, .{
                        .code = .duplicate_mixed_content_name,
                        .declaration = element.location,
                    });
                }
            }
            try self.models.append(allocator, model);
        }
        try self.checkDeclarations(allocator, limits, declarations);
        for (declarations.nesting_violations.items) |location| {
            try self.addIssue(allocator, limits, .{
                .code = .improper_parameter_entity_nesting,
                .declaration = location,
            });
        }
    }

    /// Copies immutable grammar tables and rebases their declaration strings.
    pub fn copyCompiled(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        source: *const State,
        byte_base: usize,
    ) Error!void {
        for (source.models.items) |model| {
            if (model.position_count > limits.max_content_positions) {
                return error.ContentPositionLimit;
            }
        }
        if (source.dfa_states.items.len > limits.max_content_states) {
            return error.ContentStateLimit;
        }
        if (source.transitions.items.len > limits.max_content_transitions) {
            return error.ContentTransitionLimit;
        }
        if (source.compilation_work > limits.max_compilation_work) {
            return error.CompilationWorkLimit;
        }
        self.clearRetainingCapacity();
        try self.models.appendSlice(allocator, source.models.items);
        try self.dfa_states.appendSlice(allocator, source.dfa_states.items);
        try self.dfa_items.appendSlice(allocator, source.dfa_items.items);
        for (source.transitions.items) |transition| {
            try self.transitions.append(allocator, .{
                .name = rebase(transition.name, byte_base),
                .target = transition.target,
            });
        }
        for (source.mixed_names.items) |name| {
            try self.mixed_names.append(allocator, rebase(name, byte_base));
        }
        const issue_count = @min(source.issues.items.len, limits.max_errors);
        try self.issues.appendSlice(allocator, source.issues.items[0..issue_count]);
        self.issues_truncated = source.issues_truncated or issue_count != source.issues.items.len;
    }

    pub fn beginElement(
        self: *State,
        limits: Limits,
        declarations: *const dtd.State,
        name: []const u8,
        location: SourceLocation,
    ) Error!BeginElement {
        var result: BeginElement = .{ .frame = .{} };
        if (!self.root_seen) {
            self.root_seen = true;
            if (declarations.root_name == null) {
                result.issue = .{ .code = .missing_doctype, .occurrence = location };
            } else if (!std.mem.eql(u8, declarations.rootName(), name)) {
                result.issue = .{ .code = .root_name_mismatch, .occurrence = location };
            }
        }
        const model_index = try self.findModel(limits, declarations, name);
        if (model_index == null) {
            if (result.issue == null) {
                result.issue = .{ .code = .undeclared_element, .occurrence = location };
            }
            result.frame.invalid_content = true;
            return result;
        }
        const model = self.models.items[model_index.?];
        const declaration = declarations.elements.items[model.element_index];
        result.frame = .{
            .model_index = @intCast(model_index.?),
            .state = model.start_state,
            .declared_external = declaration.declared_external,
        };
        return result;
    }

    pub fn advance(
        self: *State,
        limits: Limits,
        declarations: *const dtd.State,
        frame: *Frame,
        child_name: []const u8,
        location: SourceLocation,
    ) Error!?Issue {
        if (frame.invalid_content or frame.model_index == null) return null;
        const model = self.models.items[frame.model_index.?];
        switch (model.kind) {
            .any => return null,
            .empty => {
                frame.invalid_content = true;
                return .{ .code = .invalid_element_content, .occurrence = location };
            },
            .mixed => {
                for (self.mixed_names.items[model.mixed_start..][0..model.mixed_len]) |stored| {
                    try self.chargeComparison(limits, child_name.len +| stored.len +| 1);
                    if (std.mem.eql(u8, declarations.string(stored), child_name)) return null;
                }
                frame.invalid_content = true;
                return .{ .code = .invalid_element_content, .occurrence = location };
            },
            .children => {
                const state_index: usize = frame.state;
                const transition_start: usize = self.dfa_states.items[state_index].transition_start;
                const transition_end = if (state_index + 1 < self.dfa_states.items.len)
                    @as(usize, self.dfa_states.items[state_index + 1].transition_start)
                else
                    self.transitions.items.len;
                const transitions = self.transitions.items[transition_start..transition_end];
                for (transitions) |transition| {
                    try self.chargeComparison(limits, child_name.len +| transition.name.len +| 1);
                    if (std.mem.eql(u8, declarations.string(transition.name), child_name)) {
                        frame.state = transition.target;
                        return null;
                    }
                }
                frame.invalid_content = true;
                return .{ .code = .invalid_element_content, .occurrence = location };
            },
        }
    }

    pub fn text(
        self: *State,
        declarations: *const dtd.State,
        frame: *Frame,
        bytes: []const u8,
        allow_ignorable_whitespace: bool,
        location: SourceLocation,
    ) ?Issue {
        if (frame.invalid_content or frame.model_index == null or bytes.len == 0) return null;
        const model = self.models.items[frame.model_index.?];
        switch (model.kind) {
            .any, .mixed => return null,
            .empty => {
                frame.invalid_content = true;
                return .{ .code = .invalid_element_content, .occurrence = location };
            },
            .children => {
                if (allow_ignorable_whitespace and allXmlWhitespace(bytes)) return null;
                frame.invalid_content = true;
                return .{ .code = .invalid_element_content, .occurrence = location };
            },
        }
        _ = declarations;
    }

    pub fn contentMarker(self: *const State, frame: *Frame, location: SourceLocation) ?Issue {
        if (frame.invalid_content or frame.model_index == null) return null;
        if (self.models.items[frame.model_index.?].kind == .empty) {
            frame.invalid_content = true;
            return .{ .code = .invalid_element_content, .occurrence = location };
        }
        return null;
    }

    pub fn isIgnorableWhitespace(self: *const State, frame: Frame, bytes: []const u8) bool {
        if (frame.invalid_content or frame.model_index == null or !allXmlWhitespace(bytes)) return false;
        return self.models.items[frame.model_index.?].kind == .children;
    }

    pub fn finishElement(self: *const State, frame: *Frame, location: SourceLocation) ?Issue {
        if (frame.invalid_content or frame.model_index == null) return null;
        const model = self.models.items[frame.model_index.?];
        if (model.kind != .children) return null;
        if (!self.dfa_states.items[frame.state].accepting) {
            frame.invalid_content = true;
            return .{ .code = .invalid_element_content, .occurrence = location };
        }
        return null;
    }

    pub fn addId(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        value: []const u8,
        location: SourceLocation,
    ) Error!?Issue {
        if (self.ids.items.len == limits.max_ids or
            self.ids.items.len >= std.math.maxInt(u32) or
            value.len > limits.max_id_bytes -| self.id_bytes.items.len)
        {
            return if (value.len > limits.max_id_bytes -| self.id_bytes.items.len)
                error.IdentityBytesLimit
            else
                error.IdLimit;
        }
        try self.ensureIdSlots(allocator);
        const hash = std.hash.Wyhash.hash(0, value);
        const slot = try self.findIdSlot(limits, value, hash);
        if (self.id_slots.items[slot] != 0) {
            return .{ .code = .duplicate_id, .occurrence = location };
        }
        const offset = self.id_bytes.items.len;
        errdefer self.id_bytes.items.len = offset;
        try self.id_bytes.appendSlice(allocator, value);
        try self.ids.append(allocator, .{
            .offset = offset,
            .len = value.len,
            .location = location,
            .hash = hash,
        });
        self.id_slots.items[slot] = @intCast(self.ids.items.len);
        return null;
    }

    pub fn addIdref(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        value: []const u8,
        location: SourceLocation,
    ) Error!void {
        if (self.idrefs.items.len == limits.max_idrefs or
            value.len > limits.max_id_bytes -| self.id_bytes.items.len)
        {
            return if (value.len > limits.max_id_bytes -| self.id_bytes.items.len)
                error.IdentityBytesLimit
            else
                error.IdrefLimit;
        }
        const offset = self.id_bytes.items.len;
        try self.id_bytes.appendSlice(allocator, value);
        try self.idrefs.append(allocator, .{
            .offset = offset,
            .len = value.len,
            .location = location,
            .hash = std.hash.Wyhash.hash(0, value),
        });
    }

    pub fn unresolvedIdref(self: *State, limits: Limits, start: usize) Error!?usize {
        var index = start;
        while (index < self.idrefs.items.len) : (index += 1) {
            const reference = self.idrefs.items[index];
            if (self.id_slots.items.len == 0) return index;
            const slot = try self.findIdSlot(limits, self.idValue(reference), reference.hash);
            if (self.id_slots.items[slot] == 0) return index;
        }
        return null;
    }

    pub fn idrefLocation(self: *const State, index: usize) SourceLocation {
        return self.idrefs.items[index].location;
    }

    fn idValue(self: *const State, record: IdRecord) []const u8 {
        return self.id_bytes.items[record.offset..][0..record.len];
    }

    fn ensureIdSlots(self: *State, allocator: std.mem.Allocator) Error!void {
        const needed = self.ids.items.len + 1;
        if (self.id_slots.items.len != 0 and
            needed <= self.id_slots.items.len - self.id_slots.items.len / 4)
        {
            return;
        }
        const new_len: usize = if (self.id_slots.items.len == 0)
            16
        else
            std.math.mul(usize, self.id_slots.items.len, 2) catch
                return error.IdLimit;
        var replacement: std.ArrayList(u32) = .empty;
        errdefer replacement.deinit(allocator);
        try replacement.resize(allocator, new_len);
        @memset(replacement.items, 0);
        for (self.ids.items, 0..) |record, index| {
            var slot: usize = @intCast(record.hash & @as(u64, @intCast(new_len - 1)));
            while (replacement.items[slot] != 0) slot = (slot + 1) & (new_len - 1);
            replacement.items[slot] = @intCast(index + 1);
        }
        self.id_slots.deinit(allocator);
        self.id_slots = replacement;
    }

    fn findIdSlot(
        self: *State,
        limits: Limits,
        value: []const u8,
        hash: u64,
    ) Error!usize {
        var slot: usize = @intCast(hash & @as(u64, @intCast(self.id_slots.items.len - 1)));
        while (self.id_slots.items[slot] != 0) {
            const record = self.ids.items[self.id_slots.items[slot] - 1];
            if (record.hash == hash) {
                try self.chargeComparison(limits, value.len +| record.len +| 1);
                if (std.mem.eql(u8, value, self.idValue(record))) return slot;
            }
            slot = (slot + 1) & (self.id_slots.items.len - 1);
        }
        return slot;
    }

    fn firstElement(
        self: *State,
        declarations: *const dtd.State,
        name: dtd.StoredString,
        before: usize,
    ) ?usize {
        _ = self;
        for (declarations.elements.items[0..before], 0..) |element, index| {
            if (std.mem.eql(u8, declarations.string(name), declarations.string(element.name))) return index;
        }
        return null;
    }

    fn findModel(
        self: *State,
        limits: Limits,
        declarations: *const dtd.State,
        name: []const u8,
    ) Error!?usize {
        for (self.models.items, 0..) |model, index| {
            const stored = declarations.elements.items[model.element_index].name;
            try self.chargeComparison(limits, name.len +| stored.len +| 1);
            if (std.mem.eql(u8, name, declarations.string(stored))) return index;
        }
        return null;
    }

    fn checkDeclarations(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        declarations: *const dtd.State,
    ) Error!void {
        for (declarations.notations.items, 0..) |notation, index| {
            for (declarations.notations.items[0..index]) |prior| {
                if (std.mem.eql(u8, declarations.string(notation.name), declarations.string(prior.name))) {
                    try self.addIssue(allocator, limits, .{
                        .code = .duplicate_notation_declaration,
                        .declaration = notation.location,
                        .related = prior.location,
                    });
                    break;
                }
            }
        }
        for (declarations.entities.items) |entity| {
            if (!entity.unparsed) continue;
            if (!notationDeclared(declarations, declarations.string(entity.notation_name.?))) {
                try self.addIssue(allocator, limits, .{
                    .code = .undeclared_notation,
                    .declaration = entity.location,
                });
            }
        }
        for (declarations.attributes.items, 0..) |attribute, index| {
            var same_id: usize = 0;
            var same_notation: usize = 0;
            for (declarations.attributes.items[0 .. index + 1]) |candidate| {
                if (!std.mem.eql(
                    u8,
                    declarations.string(attribute.element_name),
                    declarations.string(candidate.element_name),
                )) continue;
                if (candidate.attribute_type == .id) same_id += 1;
                if (candidate.attribute_type == .notation) same_notation += 1;
            }
            if (attribute.attribute_type == .id) {
                if (same_id > 1) try self.addIssue(allocator, limits, .{
                    .code = .multiple_id_attributes,
                    .declaration = attribute.location,
                });
                if (attribute.default_kind != .required and attribute.default_kind != .implied) {
                    try self.addIssue(allocator, limits, .{
                        .code = .invalid_id_default,
                        .declaration = attribute.location,
                    });
                }
            }
            if (attribute.attribute_type == .notation and same_notation > 1) {
                try self.addIssue(allocator, limits, .{
                    .code = .multiple_notation_attributes,
                    .declaration = attribute.location,
                });
            }
            if (attribute.attribute_type == .notation and
                elementContentKind(declarations, declarations.string(attribute.element_name)) == .empty)
            {
                try self.addIssue(allocator, limits, .{
                    .code = .notation_on_empty_element,
                    .declaration = attribute.location,
                });
            }
            if (attribute.allowed_values) |values| {
                if (groupHasDuplicate(declarations.string(values))) {
                    try self.addIssue(allocator, limits, .{
                        .code = .duplicate_enumeration_token,
                        .declaration = attribute.location,
                    });
                }
                if (attribute.attribute_type == .notation) {
                    var iterator = GroupIterator.init(declarations.string(values));
                    while (iterator.next()) |value| {
                        if (!notationDeclared(declarations, value)) {
                            try self.addIssue(allocator, limits, .{
                                .code = .undeclared_notation,
                                .declaration = attribute.location,
                            });
                        }
                    }
                }
            }
            if (attribute.default_value) |stored_value| {
                if (!defaultValueIsLexical(
                    declarations,
                    attribute,
                    declarations.string(stored_value),
                )) {
                    try self.addIssue(allocator, limits, .{
                        .code = .invalid_attribute_value,
                        .declaration = attribute.location,
                    });
                }
            }
            if (std.mem.eql(u8, declarations.string(attribute.name), "xml:space") and
                (attribute.attribute_type != .enumeration or attribute.allowed_values == null or
                    !xmlSpaceValues(declarations.string(attribute.allowed_values.?))))
            {
                try self.addIssue(allocator, limits, .{
                    .code = .invalid_xml_space_declaration,
                    .declaration = attribute.location,
                });
            }
        }
    }

    fn compileModel(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        declarations: *const dtd.State,
        spec: dtd.StoredString,
        model: *Model,
    ) Error!bool {
        var postfix: std.ArrayList(Postfix) = .empty;
        defer postfix.deinit(allocator);
        try buildPostfix(allocator, declarations.string(spec), spec.offset, &postfix);
        var nfa: std.ArrayList(NfaState) = .empty;
        defer nfa.deinit(allocator);
        var fragments: std.ArrayList(Fragment) = .empty;
        defer fragments.deinit(allocator);
        var position_count: usize = 0;
        for (postfix.items) |token| {
            try self.chargeCompilation(limits, 1);
            switch (token) {
                .name => |name| {
                    if (position_count == limits.max_content_positions) {
                        return error.ContentPositionLimit;
                    }
                    position_count += 1;
                    const start = try appendNfaState(allocator, &nfa, limits);
                    const end = try appendNfaState(allocator, &nfa, limits);
                    nfa.items[start].name = name;
                    nfa.items[start].target = @intCast(end);
                    try fragments.append(allocator, .{ .start = @intCast(start), .end = @intCast(end) });
                },
                .sequence => {
                    const right = fragments.pop() orelse unreachable;
                    const left = fragments.pop() orelse unreachable;
                    addEpsilon(&nfa.items[left.end], right.start);
                    try fragments.append(allocator, .{ .start = left.start, .end = right.end });
                },
                .choice => {
                    const right = fragments.pop() orelse unreachable;
                    const left = fragments.pop() orelse unreachable;
                    const start = try appendNfaState(allocator, &nfa, limits);
                    const end = try appendNfaState(allocator, &nfa, limits);
                    addEpsilon(&nfa.items[start], left.start);
                    addEpsilon(&nfa.items[start], right.start);
                    addEpsilon(&nfa.items[left.end], @intCast(end));
                    addEpsilon(&nfa.items[right.end], @intCast(end));
                    try fragments.append(allocator, .{ .start = @intCast(start), .end = @intCast(end) });
                },
                .optional => {
                    const child = fragments.pop() orelse unreachable;
                    const start = try appendNfaState(allocator, &nfa, limits);
                    const end = try appendNfaState(allocator, &nfa, limits);
                    addEpsilon(&nfa.items[start], child.start);
                    addEpsilon(&nfa.items[start], @intCast(end));
                    addEpsilon(&nfa.items[child.end], @intCast(end));
                    try fragments.append(allocator, .{ .start = @intCast(start), .end = @intCast(end) });
                },
                .zero_or_more => {
                    const child = fragments.pop() orelse unreachable;
                    const start = try appendNfaState(allocator, &nfa, limits);
                    const end = try appendNfaState(allocator, &nfa, limits);
                    addEpsilon(&nfa.items[start], child.start);
                    addEpsilon(&nfa.items[start], @intCast(end));
                    addEpsilon(&nfa.items[child.end], child.start);
                    addEpsilon(&nfa.items[child.end], @intCast(end));
                    try fragments.append(allocator, .{ .start = @intCast(start), .end = @intCast(end) });
                },
                .one_or_more => {
                    const child = fragments.pop() orelse unreachable;
                    const start = try appendNfaState(allocator, &nfa, limits);
                    const end = try appendNfaState(allocator, &nfa, limits);
                    addEpsilon(&nfa.items[start], child.start);
                    addEpsilon(&nfa.items[child.end], child.start);
                    addEpsilon(&nfa.items[child.end], @intCast(end));
                    try fragments.append(allocator, .{ .start = @intCast(start), .end = @intCast(end) });
                },
            }
        }
        std.debug.assert(fragments.items.len == 1);
        const expression = fragments.items[0];
        model.position_count = position_count;
        model.state_start = self.dfa_states.items.len;

        var closure: std.ArrayList(u32) = .empty;
        defer closure.deinit(allocator);
        const visited = try allocator.alloc(bool, nfa.items.len);
        defer allocator.free(visited);
        @memset(visited, false);
        try epsilonClosure(allocator, &nfa, expression.start, &closure, visited, self, limits);
        model.start_state = try self.appendDfaState(
            allocator,
            limits,
            closure.items,
            expression.end,
        );
        var state_cursor = model.state_start;
        while (state_cursor < self.dfa_states.items.len) : (state_cursor += 1) {
            if (self.dfa_states.items.len - model.state_start > limits.max_content_states) {
                return error.ContentStateLimit;
            }
            const state = self.dfa_states.items[state_cursor];
            const items = self.dfa_items.items[state.item_start..][0..state.item_len];
            const transition_start = self.transitions.items.len;
            self.dfa_states.items[state_cursor].transition_start = @intCast(transition_start);
            var candidates: std.ArrayList(struct { name: dtd.StoredString, target: u32 }) = .empty;
            defer candidates.deinit(allocator);
            for (items) |item| {
                try self.chargeCompilation(limits, 1);
                const nfa_state = nfa.items[item];
                const name = nfa_state.name orelse continue;
                for (candidates.items) |candidate| {
                    if (std.mem.eql(u8, declarations.string(name), declarations.string(candidate.name))) {
                        return false;
                    }
                }
                try candidates.append(allocator, .{ .name = name, .target = nfa_state.target });
            }
            for (candidates.items) |candidate| {
                @memset(visited, false);
                closure.clearRetainingCapacity();
                try epsilonClosure(allocator, &nfa, candidate.target, &closure, visited, self, limits);
                std.mem.sortUnstable(u32, closure.items, {}, std.sort.asc(u32));
                const target = try self.internDfaState(
                    allocator,
                    limits,
                    model.state_start,
                    closure.items,
                    expression.end,
                );
                if (self.transitions.items.len == limits.max_content_transitions) {
                    return error.ContentTransitionLimit;
                }
                try self.transitions.append(allocator, .{
                    .name = candidate.name,
                    .target = target,
                });
            }
        }
        model.state_len = self.dfa_states.items.len - model.state_start;
        return true;
    }

    fn compileMixed(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        declarations: *const dtd.State,
        spec: dtd.StoredString,
        model: *Model,
    ) Error!bool {
        const bytes = declarations.string(spec);
        model.mixed_start = self.mixed_names.items.len;
        var duplicate = false;
        var index: usize = 0;
        while (index < bytes.len) {
            while (index < bytes.len and isMixedDelimiter(bytes[index])) index += 1;
            if (index == bytes.len) break;
            const start = index;
            while (index < bytes.len and !isMixedDelimiter(bytes[index])) index += 1;
            const value = bytes[start..index];
            if (std.mem.eql(u8, value, "#PCDATA")) continue;
            const stored: dtd.StoredString = .{ .offset = spec.offset + start, .len = value.len };
            for (self.mixed_names.items[model.mixed_start..]) |prior| {
                try self.chargeCompilation(limits, value.len +| prior.len +| 1);
                if (std.mem.eql(u8, value, declarations.string(prior))) duplicate = true;
            }
            if (self.mixed_names.items.len - model.mixed_start == limits.max_content_positions) {
                return error.ContentPositionLimit;
            }
            try self.mixed_names.append(allocator, stored);
        }
        model.mixed_len = self.mixed_names.items.len - model.mixed_start;
        model.position_count = model.mixed_len;
        return duplicate;
    }

    fn appendDfaState(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        items: []const u32,
        accept: u32,
    ) Error!u32 {
        if (self.dfa_states.items.len == limits.max_content_states) {
            return error.ContentStateLimit;
        }
        const start = self.dfa_items.items.len;
        try self.dfa_items.appendSlice(allocator, items);
        try self.dfa_states.append(allocator, .{
            .item_start = start,
            .item_len = items.len,
            .accepting = std.mem.indexOfScalar(u32, items, accept) != null,
        });
        return @intCast(self.dfa_states.items.len - 1);
    }

    fn internDfaState(
        self: *State,
        allocator: std.mem.Allocator,
        limits: Limits,
        first: usize,
        items: []const u32,
        accept: u32,
    ) Error!u32 {
        for (self.dfa_states.items[first..], first..) |state, index| {
            try self.chargeCompilation(limits, state.item_len +| items.len +| 1);
            if (std.mem.eql(u32, items, self.dfa_items.items[state.item_start..][0..state.item_len])) {
                return @intCast(index);
            }
        }
        return self.appendDfaState(allocator, limits, items, accept);
    }

    fn addIssue(self: *State, allocator: std.mem.Allocator, limits: Limits, issue: Issue) Error!void {
        if (self.issues.items.len == limits.max_errors) {
            self.issues_truncated = true;
            return;
        }
        try self.issues.append(allocator, issue);
    }

    fn chargeCompilation(self: *State, limits: Limits, amount: usize) Error!void {
        if (amount > limits.max_compilation_work -| self.compilation_work) {
            return error.CompilationWorkLimit;
        }
        self.compilation_work += amount;
    }

    fn chargeComparison(self: *State, limits: Limits, amount: usize) Error!void {
        if (amount > limits.max_comparison_work -| self.comparison_work) {
            return error.ComparisonWorkLimit;
        }
        self.comparison_work += amount;
    }
};

fn rebase(value: dtd.StoredString, base: usize) dtd.StoredString {
    return .{ .offset = base + value.offset, .len = value.len };
}

fn appendNfaState(
    allocator: std.mem.Allocator,
    states: *std.ArrayList(NfaState),
    limits: Limits,
) Error!usize {
    if (states.items.len == limits.max_content_states) {
        return error.ContentStateLimit;
    }
    try states.append(allocator, .{});
    return states.items.len - 1;
}

fn addEpsilon(state: *NfaState, target: u32) void {
    if (state.epsilon_a == null) state.epsilon_a = target else {
        std.debug.assert(state.epsilon_b == null);
        state.epsilon_b = target;
    }
}

fn epsilonClosure(
    allocator: std.mem.Allocator,
    nfa: *const std.ArrayList(NfaState),
    start: u32,
    output: *std.ArrayList(u32),
    visited: []bool,
    state: *State,
    limits: Limits,
) Error!void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, start);
    while (stack.pop()) |index| {
        try state.chargeCompilation(limits, 1);
        if (visited[index]) continue;
        visited[index] = true;
        try output.append(allocator, index);
        const item = nfa.items[index];
        if (item.epsilon_a) |next| try stack.append(allocator, next);
        if (item.epsilon_b) |next| try stack.append(allocator, next);
    }
    std.mem.sortUnstable(u32, output.items, {}, std.sort.asc(u32));
}

fn buildPostfix(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    base_offset: usize,
    output: *std.ArrayList(Postfix),
) Error!void {
    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(allocator);
    var index: usize = 0;
    skipSpace(bytes, &index);
    std.debug.assert(bytes[index] == '(');
    try groups.append(allocator, .{});
    index += 1;
    var expect_term = true;
    while (index < bytes.len) {
        skipSpace(bytes, &index);
        if (expect_term) {
            if (bytes[index] == '(') {
                try groups.append(allocator, .{});
                index += 1;
                continue;
            }
            const start = index;
            while (index < bytes.len and !isContentDelimiter(bytes[index])) index += 1;
            try output.append(allocator, .{ .name = .{ .offset = base_offset + start, .len = index - start } });
            try appendOccurrence(allocator, bytes, &index, output);
            try finishTerm(allocator, &groups, output);
            expect_term = false;
            continue;
        }
        const byte = bytes[index];
        if (byte == ',' or byte == '|') {
            const group = &groups.items[groups.items.len - 1];
            if (group.separator == 0) group.separator = byte;
            index += 1;
            expect_term = true;
            continue;
        }
        std.debug.assert(byte == ')');
        _ = groups.pop();
        index += 1;
        try appendOccurrence(allocator, bytes, &index, output);
        if (groups.items.len == 0) break;
        try finishTerm(allocator, &groups, output);
        expect_term = false;
    }
}

fn finishTerm(
    allocator: std.mem.Allocator,
    groups: *std.ArrayList(Group),
    output: *std.ArrayList(Postfix),
) Error!void {
    const group = &groups.items[groups.items.len - 1];
    group.terms += 1;
    if (group.terms > 1) {
        try output.append(allocator, if (group.separator == ',') .sequence else .choice);
    }
}

fn appendOccurrence(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    index: *usize,
    output: *std.ArrayList(Postfix),
) Error!void {
    if (index.* == bytes.len) return;
    const token: ?Postfix = switch (bytes[index.*]) {
        '?' => .optional,
        '*' => .zero_or_more,
        '+' => .one_or_more,
        else => null,
    };
    if (token) |value| {
        try output.append(allocator, value);
        index.* += 1;
    }
}

fn isContentDelimiter(byte: u8) bool {
    return byte == '(' or byte == ')' or byte == ',' or byte == '|' or
        byte == '?' or byte == '*' or byte == '+' or isSpace(byte);
}

fn isMixedDelimiter(byte: u8) bool {
    return byte == '(' or byte == ')' or byte == '|' or byte == '*' or isSpace(byte);
}

fn skipSpace(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and isSpace(bytes[index.*])) index.* += 1;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn allXmlWhitespace(bytes: []const u8) bool {
    for (bytes) |byte| if (!isSpace(byte)) return false;
    return true;
}

pub fn groupContains(bytes: []const u8, value: []const u8) bool {
    var iterator = GroupIterator.init(bytes);
    while (iterator.next()) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn groupHasDuplicate(bytes: []const u8) bool {
    var outer = GroupIterator.init(bytes);
    var outer_index: usize = 0;
    while (outer.next()) |candidate| : (outer_index += 1) {
        var inner = GroupIterator.init(bytes);
        var inner_index: usize = 0;
        while (inner.next()) |other| : (inner_index += 1) {
            if (inner_index >= outer_index) break;
            if (std.mem.eql(u8, candidate, other)) return true;
        }
    }
    return false;
}

const GroupIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    fn init(bytes: []const u8) GroupIterator {
        return .{ .bytes = bytes };
    }

    fn next(self: *GroupIterator) ?[]const u8 {
        while (self.index < self.bytes.len and
            (isSpace(self.bytes[self.index]) or self.bytes[self.index] == '(' or
                self.bytes[self.index] == ')' or self.bytes[self.index] == '|'))
        {
            self.index += 1;
        }
        if (self.index == self.bytes.len) return null;
        const start = self.index;
        while (self.index < self.bytes.len and !isSpace(self.bytes[self.index]) and
            self.bytes[self.index] != '(' and self.bytes[self.index] != ')' and
            self.bytes[self.index] != '|')
        {
            self.index += 1;
        }
        return self.bytes[start..self.index];
    }
};

fn notationDeclared(declarations: *const dtd.State, name: []const u8) bool {
    for (declarations.notations.items) |notation| {
        if (std.mem.eql(u8, declarations.string(notation.name), name)) return true;
    }
    return false;
}

fn elementContentKind(declarations: *const dtd.State, name: []const u8) ?dtd.ContentKind {
    for (declarations.elements.items) |element| {
        if (std.mem.eql(u8, declarations.string(element.name), name)) return element.content_kind;
    }
    return null;
}

fn xmlSpaceValues(bytes: []const u8) bool {
    var iterator = GroupIterator.init(bytes);
    var count: usize = 0;
    while (iterator.next()) |value| {
        if (!std.mem.eql(u8, value, "default") and !std.mem.eql(u8, value, "preserve")) return false;
        count += 1;
    }
    return count > 0;
}

fn defaultValueIsLexical(
    declarations: *const dtd.State,
    declaration: dtd.AttributeDeclaration,
    value: []const u8,
) bool {
    return switch (declaration.attribute_type) {
        .cdata => true,
        .id => dtd.validName(value),
        .idref, .entity => tokenListIsLexical(value, true, dtd.validName),
        .idrefs, .entities => tokenListIsLexical(value, false, dtd.validName),
        .nmtoken => tokenListIsLexical(value, true, dtd.validNmtoken),
        .nmtokens => tokenListIsLexical(value, false, dtd.validNmtoken),
        .enumeration, .notation => dtd.validNmtoken(value) and
            groupContains(declarations.string(declaration.allowed_values.?), value),
    };
}

fn tokenListIsLexical(
    value: []const u8,
    exactly_one: bool,
    predicate: *const fn ([]const u8) bool,
) bool {
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < value.len) {
        while (cursor < value.len and value[cursor] == ' ') cursor += 1;
        if (cursor == value.len) break;
        const start = cursor;
        while (cursor < value.len and value[cursor] != ' ') cursor += 1;
        if (!predicate(value[start..cursor])) return false;
        count += 1;
    }
    return count != 0 and (!exactly_one or count == 1);
}
