//! Caller-controlled external XML resource resolution.
//!
//! The parser never opens a path or performs network access. A resolver returns
//! a bounded byte stream whose ownership ends when `close` is called exactly
//! once by the parser.

const std = @import("std");
const encoding = @import("encoding.zig");

/// Kind of external XML resource being requested.
pub const EntityKind = enum {
    external_subset,
    parameter_entity,
    general_entity,
};

/// Source position at which an external resource was included.
pub const InclusionLocation = struct {
    source_id: u32,
    byte_offset: u64,
};

/// One resolver request. All slices are borrowed for the callback duration.
pub const Request = struct {
    kind: EntityKind,
    name: ?[]const u8 = null,
    public_id: ?[]const u8 = null,
    system_id: []const u8,
    base_id: ?[]const u8 = null,
    inclusion: InclusionLocation,
};

/// Result of one stream read.
pub const ReadResult = union(enum) {
    bytes: usize,
    end,
    io_failure,
    cancelled,
};

/// Successfully acquired caller-owned external source.
pub const Source = struct {
    context: ?*anyopaque,
    /// Nonzero identifier unique among sources returned for one document parse.
    source_id: u32,
    base_id: ?[]const u8 = null,
    encoding_hint: ?encoding.SourceEncoding = null,
    transcoder: ?encoding.Transcoder = null,
    readFn: *const fn (?*anyopaque, []u8) ReadResult,
    closeFn: *const fn (?*anyopaque) void,

    /// Reads into a nonempty bounded destination.
    pub fn read(self: Source, output: []u8) ReadResult {
        std.debug.assert(output.len != 0);
        const result = self.readFn(self.context, output);
        if (result == .bytes and (result.bytes == 0 or result.bytes > output.len)) {
            return .io_failure;
        }
        return result;
    }

    /// Ends ownership of the source.
    pub fn close(self: Source) void {
        self.closeFn(self.context);
    }
};

/// Policy or acquisition outcome returned by a resolver.
pub const Result = union(enum) {
    source: Source,
    not_found,
    forbidden,
    unsupported_scheme,
    resource_limit,
    cancelled,
    io_failure,
};

/// Caller-owned resolver callback.
pub const Resolver = struct {
    context: ?*anyopaque,
    resolveFn: *const fn (?*anyopaque, Request) Result,

    /// Resolves one request without granting the parser ambient authority.
    pub fn resolve(self: Resolver, request: Request) Result {
        return self.resolveFn(self.context, request);
    }
};

/// Optional filesystem resolver confined to one already-open directory.
///
/// System identifiers are interpreted as slash-separated relative paths. The
/// resolver rejects schemes, absolute paths, fragments, backslashes,
/// symlinks, directories, root escapes, and every path that cannot be opened
/// component by component beneath `root`.
pub const RootedFilesystem = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    next_source_id: u32 = 1,

    const FileSource = struct {
        owner: *RootedFilesystem,
        file: std.Io.File,
        base_id: []u8,

        fn read(context: ?*anyopaque, output: []u8) ReadResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const len = self.file.readStreaming(self.owner.io, &.{output}) catch |err| switch (err) {
                error.EndOfStream => return .end,
                else => return .io_failure,
            };
            return if (len == 0) .end else .{ .bytes = len };
        }

        fn close(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const owner = self.owner;
            self.file.close(owner.io);
            owner.allocator.free(self.base_id);
            owner.allocator.destroy(self);
        }
    };

    /// Initializes a resolver over a caller-owned open root directory.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) RootedFilesystem {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    /// Returns the callback interface borrowed from this resolver.
    pub fn resolver(self: *RootedFilesystem) Resolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: ?*anyopaque, request: Request) Result {
        const self: *RootedFilesystem = @ptrCast(@alignCast(context.?));
        if (self.next_source_id == 0) return .resource_limit;
        const path = self.resolvePath(request.base_id, request.system_id) catch |err| switch (err) {
            error.Forbidden => return .forbidden,
            error.OutOfMemory => return .resource_limit,
        };
        defer self.allocator.free(path);
        const file = self.openBeneath(path) catch |err| switch (err) {
            error.FileNotFound => return .not_found,
            error.AccessDenied, error.SymLinkLoop, error.NotDir, error.IsDir => {
                return .forbidden;
            },
            else => return .io_failure,
        };
        const stat = file.stat(self.io) catch {
            file.close(self.io);
            return .io_failure;
        };
        if (stat.kind != .file) {
            file.close(self.io);
            return .forbidden;
        }
        const state = self.allocator.create(FileSource) catch {
            file.close(self.io);
            return .resource_limit;
        };
        const base_id = self.allocator.dupe(u8, path) catch {
            file.close(self.io);
            self.allocator.destroy(state);
            return .resource_limit;
        };
        state.* = .{ .owner = self, .file = file, .base_id = base_id };
        const source_id = self.next_source_id;
        self.next_source_id +%= 1;
        return .{ .source = .{
            .context = state,
            .source_id = source_id,
            .base_id = base_id,
            .readFn = FileSource.read,
            .closeFn = FileSource.close,
        } };
    }

    fn resolvePath(
        self: *RootedFilesystem,
        base_id: ?[]const u8,
        system_id: []const u8,
    ) error{ Forbidden, OutOfMemory }![]u8 {
        if (!safeIdentifier(system_id)) return error.Forbidden;
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(self.allocator);
        if (base_id) |base| {
            if (!safeRelativePath(base)) return error.Forbidden;
            if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| {
                try path.appendSlice(self.allocator, base[0..slash]);
            }
        }
        var components = std.mem.splitScalar(u8, system_id, '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) {
                if (path.items.len == 0) return error.Forbidden;
                path.items.len = std.mem.lastIndexOfScalar(u8, path.items, '/') orelse 0;
                continue;
            }
            if (path.items.len != 0) try path.append(self.allocator, '/');
            try path.appendSlice(self.allocator, component);
        }
        if (path.items.len == 0) return error.Forbidden;
        return path.toOwnedSlice(self.allocator);
    }

    fn openBeneath(self: *RootedFilesystem, path: []const u8) !std.Io.File {
        var current = self.root;
        var current_owned = false;
        defer if (current_owned) current.close(self.io);
        var components = std.mem.splitScalar(u8, path, '/');
        var component = components.next().?;
        while (components.next()) |next| {
            const child = try current.openDir(self.io, component, .{ .follow_symlinks = false });
            if (current_owned) current.close(self.io);
            current = child;
            current_owned = true;
            component = next;
        }
        return current.openFile(self.io, component, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        });
    }
};

fn safeRelativePath(path: []const u8) bool {
    if (!safeIdentifier(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn safeIdentifier(path: []const u8) bool {
    return path.len != 0 and path[0] != '/' and
        std.mem.indexOfAny(u8, path, "\\:#?") == null;
}

test "[unit] - [resolver source]: validates bounded reads and closes explicitly" {
    const Context = struct {
        input: []const u8,
        cursor: usize = 0,
        closes: usize = 0,

        fn read(context: ?*anyopaque, output: []u8) ReadResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.cursor == self.input.len) return .end;
            const len = @min(output.len, self.input.len - self.cursor);
            @memcpy(output[0..len], self.input[self.cursor..][0..len]);
            self.cursor += len;
            return .{ .bytes = len };
        }

        fn close(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closes += 1;
        }
    };
    var context: Context = .{ .input = "external" };
    const source: Source = .{
        .context = &context,
        .source_id = 7,
        .readFn = Context.read,
        .closeFn = Context.close,
    };
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), source.read(&buffer).bytes);
    try std.testing.expectEqualStrings("exte", &buffer);
    source.close();
    try std.testing.expectEqual(@as(usize, 1), context.closes);
}

test "[unit] - [resolver source]: rejects invalid callback byte counts" {
    const InvalidReader = struct {
        fn read(_: ?*anyopaque, output: []u8) ReadResult {
            return .{ .bytes = output.len + 1 };
        }

        fn close(_: ?*anyopaque) void {}
    };
    const source: Source = .{
        .context = null,
        .source_id = 1,
        .readFn = InvalidReader.read,
        .closeFn = InvalidReader.close,
    };
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(ReadResult.io_failure, source.read(&buffer));
}

test "[unit] - [rooted resolver]: rejects absolute, escaping, scheme, and fragment paths" {
    try std.testing.expect(!safeRelativePath("/etc/passwd"));
    try std.testing.expect(!safeRelativePath("../outside.dtd"));
    try std.testing.expect(!safeRelativePath("a/../outside.dtd"));
    try std.testing.expect(!safeRelativePath("https://example.test/a.dtd"));
    try std.testing.expect(!safeRelativePath("a.dtd#fragment"));
    try std.testing.expect(!safeRelativePath("a\\b.dtd"));
    try std.testing.expect(safeRelativePath("schemas/document.dtd"));

    var rooted = RootedFilesystem.init(std.testing.allocator, std.testing.io, std.Io.Dir.cwd());
    const nested = try rooted.resolvePath("subdir1/entity.pe", "../subdir2/entity.ent");
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("subdir2/entity.ent", nested);
    try std.testing.expectError(error.Forbidden, rooted.resolvePath(null, "../outside.dtd"));

    var failing_rooted = RootedFilesystem.init(
        std.testing.failing_allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
    );
    const failure = failing_rooted.resolver().resolve(.{
        .kind = .external_subset,
        .system_id = "schema.dtd",
        .inclusion = .{ .source_id = 0, .byte_offset = 0 },
    });
    try std.testing.expect(failure == .resource_limit);
}
