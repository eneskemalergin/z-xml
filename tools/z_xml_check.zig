//! Streaming corpus adapter for implemented XML 1.0 profiles.

const std = @import("std");
const xml = @import("z_xml");
const check_options = @import("check_options");

const CONFIG = if (check_options.dtd)
    if (check_options.namespaces)
        xml.Configs.XML10_NAMESPACES_NONVALIDATING
    else
        xml.Configs.XML10_NONVALIDATING
else if (check_options.general_encodings)
    if (check_options.namespaces)
        xml.Configs.XML10_NAMESPACES_NO_DTD_FAST
    else
        xml.Configs.XML10_NO_DTD_FAST
else if (check_options.namespaces)
    xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD_FAST
else
    xml.Configs.XML10_UTF8_NO_DTD_FAST;
const INPUT_BUFFER_SIZE = 64 * 1024;

const Stats = struct {
    elements: u64 = 0,
    attributes: u64 = 0,
    text_bytes: u64 = 0,
    checksum: u64 = 14695981039346656037,

    fn bytes(self: *Stats, value: []const u8) void {
        for (value) |byte| {
            self.checksum ^= byte;
            self.checksum *%= 1099511628211;
        }
    }

    fn marker(self: *Stats, value: u8) void {
        self.bytes(&.{value});
    }

    fn observe(self: *Stats, event: xml.Event(CONFIG)) void {
        switch (event) {
            .start_element => |start| {
                self.elements += 1;
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
                    self.marker(2);
                    self.bytes(attribute.name.raw);
                    self.marker(3);
                    self.bytes(attribute.value);
                }
            },
            .end_element => |end| {
                self.marker(4);
                self.bytes(end.name.raw);
            },
            .text => |text| {
                self.text_bytes += text.bytes.len;
                self.bytes(text.bytes);
            },
            else => {},
        }
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
    var options: xml.Options(CONFIG) = .{};
    if (comptime check_options.dtd) {
        options.dtd_limits.max_comparison_work = 512 * 1024 * 1024;
        options.dtd_limits.max_entity_references = 8 * 1024 * 1024;
        options.dtd_limits.max_expanded_bytes = 256 * 1024 * 1024;
        options.dtd_limits.max_entity_replacement_bytes = 64 * 1024 * 1024;
        options.dtd_limits.max_expansion_ratio = 1000;
        const directory = std.fs.path.dirname(args[1]) orelse ".";
        root_dir = if (std.fs.path.isAbsolute(directory))
            try std.Io.Dir.openDirAbsolute(init.io, directory, .{})
        else
            try std.Io.Dir.cwd().openDir(init.io, directory, .{});
        filesystem_resolver = .init(init.gpa, init.io, root_dir.?);
        options.resolver = .{
            .policy = .resolve,
            .resolver = filesystem_resolver.resolver(),
            .document_base_id = std.fs.path.basename(args[1]),
        };
    }
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var reader = try xml.IoReader(CONFIG).init(init.gpa, options, &file_reader.interface);
    defer reader.deinit();

    var stats: Stats = .{};
    while (true) {
        const step = reader.next() catch |err| {
            if (reader.diagnostic()) |diagnostic| {
                std.debug.print(
                    "z-xml-check: {s} at source {d} byte {d}\n",
                    .{ @tagName(diagnostic.code), diagnostic.primary.source_id, diagnostic.primary.byte_offset },
                );
            }
            if (statusForReadError(err)) |status| return status;
            return err;
        };
        switch (step) {
            .event => |event| stats.observe(event),
            .done => break,
            .need_input => return error.InvalidState,
        }
    }

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

fn statusForReadError(err: xml.ReadError) ?u8 {
    return switch (err) {
        error.InvalidXml, error.InvalidDtd, error.NotValid => 2,
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
    try std.testing.expectEqual(@as(?u8, null), statusForReadError(error.UnsupportedFeature));
    try std.testing.expectEqual(@as(?u8, null), statusForReadError(error.ReadFailed));
}
