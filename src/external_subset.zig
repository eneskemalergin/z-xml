//! Immutable, caller-owned compiled external DTD subsets.

const std = @import("std");
const dtd = @import("dtd.zig");
const validation = @import("validation.zig");

pub const Provider = dtd.ExternalProvider;
pub const ProviderError = dtd.ParseError;
pub const Request = dtd.ExternalRequest;
pub const Result = dtd.ExternalResult;
pub const Content = dtd.ExternalContent;

pub const CompileError = dtd.ParseError || error{InvalidOptions};

/// Construction policy and limits for one compiled external subset.
pub const Options = struct {
    public_id: ?[]const u8 = null,
    base_id: ?[]const u8 = null,
    /// Nonzero diagnostic identity assigned to the top-level declaration source.
    source_id: u32 = 1,
    dtd_limits: dtd.Limits = .{},
    validation_limits: validation.Limits = .{},
    /// Optional synchronous provider for external parameter entities.
    provider: ?Provider = null,
};

/// Caller-owned capacity retained by a compiled subset.
pub const MemoryUsage = struct {
    declaration_capacity: usize,
    validation_capacity: usize,
    identifier_bytes: usize,
    source_capacity: usize,
};

/// Position in one normalized declaration source.
pub const SourcePosition = struct {
    byte_offset: u64,
    line: u64,
    byte_column: u64,
};

/// Source and normalized byte offset that included another declaration source.
pub const Inclusion = struct {
    source_id: u32,
    offset: usize,
};

const SourceRecord = struct {
    bytes: []u8,
    source_id: u32,
    inclusion: ?Inclusion,
};

/// Immutable declaration grammar borrowed by compatible validating readers.
pub const ExternalSubset = struct {
    allocator: std.mem.Allocator,
    declarations: dtd.State = .{},
    compiled: validation.State = .{},
    system_id: []u8,
    public_id: ?[]u8 = null,
    sources: std.ArrayList(SourceRecord) = .empty,

    /// Compiles decoded UTF-8 declarations whose line endings are already normalized.
    /// Nested declaration bytes returned by `options.provider` follow the same contract.
    pub fn compileDecoded(
        allocator: std.mem.Allocator,
        system_id: []const u8,
        declaration_bytes: []const u8,
        options: Options,
    ) CompileError!ExternalSubset {
        if (system_id.len == 0 or options.source_id == 0 or
            !options.dtd_limits.validate() or !options.validation_limits.validate())
        {
            return error.InvalidOptions;
        }
        var result: ExternalSubset = .{
            .allocator = allocator,
            .system_id = try allocator.dupe(u8, system_id),
        };
        errdefer result.deinit();
        if (options.public_id) |public_id| {
            result.public_id = try allocator.dupe(u8, public_id);
        }
        const root_bytes = try allocator.dupe(u8, declaration_bytes);
        result.sources.append(allocator, .{
            .bytes = root_bytes,
            .source_id = options.source_id,
            .inclusion = null,
        }) catch |err| {
            allocator.free(root_bytes);
            return err;
        };
        var capture = ProviderCapture{
            .allocator = allocator,
            .owner = &result,
            .upstream = options.provider,
        };
        try result.declarations.parseExternalSubset(
            allocator,
            options.dtd_limits,
            root_bytes,
            options.base_id,
            options.source_id,
            if (options.provider != null) capture.provider() else null,
        );
        result.compiled.prepare(
            allocator,
            options.validation_limits,
            &result.declarations,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.LimitExceeded,
        };
        return result;
    }

    /// Releases all declarations, grammar tables, identities, and source maps.
    pub fn deinit(self: *ExternalSubset) void {
        self.compiled.deinit(self.allocator);
        self.declarations.deinit(self.allocator);
        for (self.sources.items) |source| self.allocator.free(source.bytes);
        self.sources.deinit(self.allocator);
        if (self.public_id) |public_id| self.allocator.free(public_id);
        self.allocator.free(self.system_id);
        self.* = undefined;
    }

    /// Returns retained capacities without changing the subset.
    pub fn memoryUsage(self: *const ExternalSubset) MemoryUsage {
        return .{
            .declaration_capacity = self.declarations.capacity(),
            .validation_capacity = self.compiled.capacity(),
            .identifier_bytes = self.system_id.len + if (self.public_id) |value| value.len else 0,
            .source_capacity = self.sources.capacity *| @sizeOf(SourceRecord) +|
                sourceBytes(self.sources.items),
        };
    }

    pub fn matches(self: *const ExternalSubset, declarations: *const dtd.State) bool {
        const system = declarations.external_id.system_id orelse return false;
        if (!std.mem.eql(u8, self.system_id, declarations.string(system))) return false;
        const declared_public = declarations.external_id.public_id;
        if (self.public_id) |public_id| {
            return declared_public != null and
                std.mem.eql(u8, public_id, declarations.string(declared_public.?));
        }
        return declared_public == null;
    }

    pub fn declarationState(self: *const ExternalSubset) *const dtd.State {
        return &self.declarations;
    }

    pub fn compiledState(self: *const ExternalSubset) *const validation.State {
        return &self.compiled;
    }

    pub fn sourcePosition(self: *const ExternalSubset, source_id: u32, offset: usize) ?SourcePosition {
        const source = self.findSource(source_id) orelse return null;
        var position: SourcePosition = .{ .byte_offset = 0, .line = 1, .byte_column = 1 };
        for (source.bytes[0..@min(offset, source.bytes.len)]) |byte| {
            position.byte_offset += 1;
            if (byte == '\n') {
                position.line += 1;
                position.byte_column = 1;
            } else {
                position.byte_column += 1;
            }
        }
        return position;
    }

    pub fn sourceInclusion(self: *const ExternalSubset, source_id: u32) ?Inclusion {
        const source = self.findSource(source_id) orelse return null;
        return source.inclusion;
    }

    pub fn hasSource(self: *const ExternalSubset, source_id: u32) bool {
        return self.findSource(source_id) != null;
    }

    fn findSource(self: *const ExternalSubset, source_id: u32) ?SourceRecord {
        for (self.sources.items) |source| {
            if (source.source_id == source_id) return source;
        }
        return null;
    }
};

const ProviderCapture = struct {
    allocator: std.mem.Allocator,
    owner: *ExternalSubset,
    upstream: ?Provider,

    fn provider(self: *@This()) Provider {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: ?*anyopaque, request: Request) ProviderError!Result {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const result = try self.upstream.?.resolve(request);
        return switch (result) {
            .skipped => error.UnsupportedFeature,
            .content => |content| blk: {
                if (content.source_id == 0 or self.owner.findSource(content.source_id) != null) {
                    return error.InvalidDtd;
                }
                const bytes = try self.allocator.dupe(u8, content.bytes);
                errdefer self.allocator.free(bytes);
                try self.owner.sources.append(self.allocator, .{
                    .bytes = bytes,
                    .source_id = content.source_id,
                    .inclusion = .{
                        .source_id = request.inclusion_source_id,
                        .offset = request.inclusion_offset,
                    },
                });
                break :blk .{ .content = .{
                    .bytes = bytes,
                    .base_id = content.base_id,
                    .source_id = content.source_id,
                } };
            },
        };
    }
};

fn sourceBytes(sources: []const SourceRecord) usize {
    var total: usize = 0;
    for (sources) |source| total +|= source.bytes.len;
    return total;
}
