//! Runs one compiled z-xml Reader profile as a streaming corpus adapter.
//!
//! The adapter reads one file and writes deterministic event counts and a checksum. DTD-enabled
//! profiles resolve external sources relative to that file. XML rejection returns status 2,
//! resource exhaustion returns status 3, and other operational failures return status 1.

const std = @import("std");
const xml = @import("z_xml");
const check_options = @import("check_options");

const INPUT_BUFFER_SIZE = 64 * 1024;

const Stats = struct {
    document_starts: u8 = 0,
    document_ends: u8 = 0,
    elements: u64 = 0,
    end_elements: u64 = 0,
    attributes: u64 = 0,
    text_bytes: u64 = 0,
    checksum: u64 = 14695981039346656037,
    semantic_match: bool = true,

    fn bytes(self: *Stats, value: []const u8) void {
        for (value) |byte| {
            self.checksum ^= byte;
            self.checksum *%= 1099511628211;
        }
    }

    fn marker(self: *Stats, value: u8) void {
        self.bytes(&.{value});
    }

    fn observe(self: *Stats, event: xml.Event) void {
        self.observePayload(event.data);
    }

    fn observePayload(self: *Stats, payload: anytype) void {
        switch (payload) {
            .document_start => self.document_starts +|= 1,
            .start_element => |start| {
                self.elements += 1;
                self.observeName(start.name);
                if (!check_options.namespaces and start.namespace_declarations.len != 0) {
                    self.semantic_match = false;
                }
                self.marker(1);
                self.bytes(start.name.raw);
                if (@hasField(@TypeOf(start), "namespace_declarations")) {
                    for (start.namespace_declarations) |declaration| {
                        self.marker(5);
                        self.bytes(declaration.prefix orelse "");
                        self.marker(6);
                        self.bytes(declaration.namespace_uri);
                    }
                }
                for (start.attributes) |attribute| {
                    self.attributes += 1;
                    self.observeName(attribute.name);
                    self.marker(2);
                    self.bytes(attribute.name.raw);
                    self.marker(3);
                    self.bytes(attribute.value);
                }
            },
            .end_element => |end| {
                self.end_elements += 1;
                self.observeName(end.name);
                self.marker(4);
                self.bytes(end.name.raw);
            },
            .text => |text| {
                self.text_bytes += text.bytes.len;
                self.bytes(text.bytes);
            },
            .document_end => |result| {
                self.document_ends +|= 1;
                if (!check_options.validating and result.dtd_validity != .not_requested) {
                    self.semantic_match = false;
                }
            },
            else => {},
        }
    }

    fn observeName(self: *Stats, name: xml.Name) void {
        if ((name.expanded != null) != check_options.namespaces) {
            self.semantic_match = false;
        }
    }

    fn complete(self: Stats) bool {
        return self.semantic_match and self.document_starts == 1 and
            self.document_ends == 1 and self.elements == self.end_elements;
    }
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-check: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: z-xml-check FILE\n", .{});
        return 64;
    }

    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var root_dir: ?std.Io.Dir = null;
    defer if (root_dir) |dir| dir.close(init.io);
    var filesystem_resolver: if (check_options.dtd) xml.RootedFilesystemResolver else void = undefined;
    if (comptime check_options.dtd) {
        const directory = std.fs.path.dirname(args[1]) orelse ".";
        root_dir = if (std.fs.path.isAbsolute(directory))
            try std.Io.Dir.openDirAbsolute(init.io, directory, .{})
        else
            try std.Io.Dir.cwd().openDir(init.io, directory, .{});
        filesystem_resolver = .init(init.gpa, init.io, root_dir.?);
    }
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var stats: Stats = .{};
    var options: xml.ReaderOptions = .{
        .namespaces = if (check_options.namespaces) .process else .raw,
        .dtd = if (check_options.validating)
            .{ .validate = .{} }
        else if (check_options.dtd)
            .process
        else
            .reject,
    };
    if (comptime check_options.dtd) {
        options.limits.max_dtd_comparison_work = 512 * 1024 * 1024;
        options.limits.max_dtd_entity_references = 8 * 1024 * 1024;
        options.limits.max_dtd_expanded_bytes = 256 * 1024 * 1024;
        options.limits.max_dtd_entity_replacement_bytes = 64 * 1024 * 1024;
        options.limits.max_dtd_expansion_ratio = 1000;
        options.external = .resolve;
        options.resolver = filesystem_resolver.resolver();
        options.document_base_id = std.fs.path.basename(args[1]);
    }
    if (comptime check_options.validating) {
        options.limits.max_validation_ids = 8 * 1024 * 1024;
        options.limits.max_validation_idrefs = 8 * 1024 * 1024;
        options.limits.max_validation_identity_bytes = 256 * 1024 * 1024;
        options.limits.max_validation_comparison_work = 512 * 1024 * 1024;
    }
    var reader = try xml.Reader.init(
        init.gpa,
        .{ .stream = &file_reader.interface },
        options,
    );
    defer reader.deinit();
    while (true) {
        const event = reader.next() catch |err| {
            if (reader.diagnostic()) |diagnostic| printDiagnostic(diagnostic);
            if (statusForReadError(err)) |status| return status;
            return err;
        };
        if (event) |value| {
            if (comptime check_options.validating) switch (value.data) {
                .document_end => |result| if (result.dtd_validity != .valid) return 2,
                else => {},
            };
            stats.observe(value);
        } else break;
    }
    if (!stats.complete()) return error.SemanticMismatch;

    var output_buffer: [160]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    try output.print(
        "{{\"elements\":{d},\"attributes\":{d},\"text_bytes\":{d},\"checksum\":\"{x:0>16}\"}}\n",
        .{ stats.elements, stats.attributes, stats.text_bytes, stats.checksum },
    );
    try output.flush();
    return 0;
}

fn printDiagnostic(diagnostic: anytype) void {
    std.debug.print(
        "z-xml-check: {s} at source {d} byte {d}\n",
        .{ @tagName(diagnostic.code), diagnostic.primary.source_id, diagnostic.primary.byte_offset },
    );
}

fn statusForReadError(err: anyerror) ?u8 {
    return switch (err) {
        error.InvalidXml,
        error.InvalidDtd,
        error.NotValid,
        error.InvalidEncoding,
        error.UnsupportedEncoding,
        error.UnsupportedVersion,
        error.DtdForbidden,
        => 2,
        error.LimitExceeded, error.OutOfMemory => 3,
        else => null,
    };
}

// --- Tests ---

test "[unit] - [corpus adapter]: maps parser outcomes to contract statuses" {
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.InvalidXml));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.InvalidDtd));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.NotValid));
    try std.testing.expectEqual(@as(?u8, 3), statusForReadError(error.LimitExceeded));
    try std.testing.expectEqual(@as(?u8, 3), statusForReadError(error.OutOfMemory));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.InvalidEncoding));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.UnsupportedVersion));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.DtdForbidden));
    try std.testing.expectEqual(@as(?u8, null), statusForReadError(error.UnsupportedFeature));
    try std.testing.expectEqual(@as(?u8, null), statusForReadError(error.ReadFailed));
}

test "[unit] - [corpus adapter]: requires one balanced document" {
    var stats: Stats = .{};
    try std.testing.expect(!stats.complete());
    stats.document_starts = 1;
    stats.document_ends = 1;
    stats.elements = 2;
    stats.end_elements = 2;
    try std.testing.expect(stats.complete());
    stats.semantic_match = false;
    try std.testing.expect(!stats.complete());
}
