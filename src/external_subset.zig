//! Immutable, caller-owned compiled external DTD subsets.

const std = @import("std");
const dtd = @import("dtd.zig");
const validation = @import("validation.zig");
const unicode_normalization = @import("unicode_normalization.zig");

pub const Provider = dtd.ExternalProvider;
pub const ProviderError = dtd.ParseError;
pub const Request = dtd.ExternalRequest;
pub const Result = dtd.ExternalResult;
pub const Content = dtd.ExternalContent;

pub const CompileError = dtd.ParseError || error{InvalidOptions};

/// Construction policy and limits for one compiled external subset.
pub const Options = struct {
    /// XML character rules used while compiling declaration values.
    version: dtd.XmlVersion = .xml10,
    public_id: ?[]const u8 = null,
    base_id: ?[]const u8 = null,
    /// Nonzero diagnostic identity assigned to the top-level declaration source.
    source_id: u32 = 1,
    dtd_limits: dtd.Limits = .{},
    validation_limits: validation.Limits = .{},
    /// Maximum declaration sources retained by the compiled subset.
    max_sources: usize = 256,
    /// Maximum cumulative bytes retained from declaration sources.
    max_source_bytes: usize = 32 * 1024 * 1024,
    /// Maximum bytes accepted in one system, public, or base identifier.
    max_identifier_bytes: usize = 64 * 1024,
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

/// Normalization outcome retained for a decoded XML 1.1 declaration source.
pub const NormalizationFindingKind = enum { not_nfc, unknown_character };

/// First normalization finding retained by a compiled subset.
pub const NormalizationFinding = struct {
    kind: NormalizationFindingKind,
    source_id: u32,
    byte_offset: u64,
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
    normalization_finding: ?NormalizationFinding = null,

    /// Compiles decoded UTF-8 declarations whose line endings are already normalized.
    /// Nested declaration bytes returned by `options.provider` follow the same contract.
    pub fn compileDecoded(
        allocator: std.mem.Allocator,
        system_id: []const u8,
        declaration_bytes: []const u8,
        options: Options,
    ) CompileError!ExternalSubset {
        if (system_id.len == 0 or options.source_id == 0 or
            !options.dtd_limits.validate() or !options.validation_limits.validate() or
            options.max_sources == 0 or options.max_source_bytes == 0 or
            options.max_identifier_bytes == 0)
        {
            return error.InvalidOptions;
        }
        if (system_id.len > options.max_identifier_bytes or
            (options.public_id != null and
                options.public_id.?.len > options.max_identifier_bytes) or
            (options.base_id != null and
                options.base_id.?.len > options.max_identifier_bytes) or
            declaration_bytes.len > options.max_source_bytes)
        {
            return error.LimitExceeded;
        }
        var result: ExternalSubset = .{
            .allocator = allocator,
            .system_id = try allocator.dupe(u8, system_id),
        };
        errdefer result.deinit();
        result.declarations.version = options.version;
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
            .max_sources = options.max_sources,
            .max_source_bytes = options.max_source_bytes,
            .max_identifier_bytes = options.max_identifier_bytes,
            .source_bytes = declaration_bytes.len,
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
            true,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.LimitExceeded,
        };
        if (options.version == .xml11) result.scanNormalizationSources();
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
        if (self.declarations.version != declarations.version) return false;
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

    /// Returns the first retained normalization finding, if any.
    pub fn normalizationFinding(self: *const ExternalSubset) ?NormalizationFinding {
        return self.normalization_finding;
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

    fn scanNormalizationSources(self: *ExternalSubset) void {
        for (self.sources.items) |source| {
            var checker: unicode_normalization.Checker = .{};
            var view = std.unicode.Utf8View.init(source.bytes) catch continue;
            var iterator = view.iterator();
            var offset: u64 = 0;
            while (iterator.nextCodepointSlice()) |scalar| {
                const codepoint = std.unicode.utf8Decode(scalar) catch unreachable;
                if (checker.add(@intCast(codepoint))) |issue| {
                    const finding: NormalizationFinding = .{
                        .kind = switch (issue) {
                            .not_nfc => .not_nfc,
                            .unknown_character => .unknown_character,
                        },
                        .source_id = source.source_id,
                        .byte_offset = offset,
                    };
                    if (self.normalization_finding == null or
                        (finding.kind == .not_nfc and
                            self.normalization_finding.?.kind == .unknown_character))
                    {
                        self.normalization_finding = finding;
                    }
                    if (finding.kind == .not_nfc) break;
                    checker.reset();
                }
                offset += scalar.len;
            }
        }
    }
};

const ProviderCapture = struct {
    allocator: std.mem.Allocator,
    owner: *ExternalSubset,
    upstream: ?Provider,
    max_sources: usize,
    max_source_bytes: usize,
    max_identifier_bytes: usize,
    source_bytes: usize,

    fn provider(self: *@This()) Provider {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: ?*anyopaque, request: Request) ProviderError!Result {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.owner.sources.items.len == self.max_sources or
            request.system_id.len > self.max_identifier_bytes or
            (request.public_id != null and
                request.public_id.?.len > self.max_identifier_bytes) or
            (request.base_id != null and
                request.base_id.?.len > self.max_identifier_bytes))
        {
            return error.LimitExceeded;
        }
        const result = try self.upstream.?.resolve(request);
        return switch (result) {
            .skipped => error.UnsupportedFeature,
            .content => |content| blk: {
                if (content.source_id == 0 or self.owner.findSource(content.source_id) != null) {
                    return error.InvalidDtd;
                }
                if (content.bytes.len > self.max_source_bytes -| self.source_bytes or
                    (content.base_id != null and
                        content.base_id.?.len > self.max_identifier_bytes))
                {
                    return error.LimitExceeded;
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
                self.source_bytes += content.bytes.len;
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
