//! Repeated streaming validation adapter for fresh and compiled DTD comparisons.

const std = @import("std");
const xml = @import("z_xml");
const repeat_options = @import("repeat_options");

const input_buffer_size = 64 * 1024;

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

    fn observe(self: *Stats, event: xml.Event) !void {
        switch (event.data) {
            .start_element => |start| {
                self.elements += 1;
                self.bytes(&.{1});
                self.bytes(start.name.raw);
                for (start.attributes) |attribute| {
                    self.attributes += 1;
                    self.bytes(&.{2});
                    self.bytes(attribute.name.raw);
                    self.bytes(&.{3});
                    self.bytes(attribute.value);
                }
            },
            .end_element => |end| {
                self.bytes(&.{4});
                self.bytes(end.name.raw);
            },
            .text => |text| {
                self.text_bytes += text.bytes.len;
                self.bytes(text.bytes);
            },
            .document_end => |end| if (end.dtd_validity != .valid) return error.NotValid,
            else => {},
        }
    }
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-validation-repeat: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: z-xml-validation-repeat DTD XML REPETITIONS\n", .{});
        return 64;
    }
    const repetitions = try std.fmt.parseInt(usize, args[3], 10);
    if (repetitions == 0) return error.InvalidRepetitionCount;

    const directory = std.fs.path.dirname(args[2]) orelse ".";
    var root_dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(init.io, directory, .{})
    else
        try std.Io.Dir.cwd().openDir(init.io, directory, .{});
    defer root_dir.close(init.io);
    var filesystem_resolver = xml.RootedFilesystemResolver.init(init.gpa, init.io, root_dir);

    var subset: ?xml.ExternalSubset = null;
    defer if (subset) |*value| value.deinit();
    if (comptime repeat_options.reuse) {
        const declaration_bytes = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            args[1],
            init.gpa,
            .limited(64 * 1024 * 1024),
        );
        defer init.gpa.free(declaration_bytes);
        subset = try xml.ExternalSubset.compileDecoded(
            init.gpa,
            std.fs.path.basename(args[1]),
            declaration_bytes,
            .{ .base_id = std.fs.path.basename(args[1]), .source_id = 1 },
        );
    }

    var totals: Stats = .{};
    for (0..repetitions) |_| {
        const file = try std.Io.Dir.cwd().openFile(init.io, args[2], .{});
        defer file.close(init.io);
        var options: xml.ReaderOptions = .{
            .dtd = .{ .validate = .{} },
            .external = .resolve,
            .resolver = filesystem_resolver.resolver(),
            .document_base_id = std.fs.path.basename(args[2]),
        };
        options.limits.max_dtd_comparison_work = 512 * 1024 * 1024;
        options.limits.max_validation_ids = 8 * 1024 * 1024;
        options.limits.max_validation_idrefs = 8 * 1024 * 1024;
        options.limits.max_validation_identity_bytes = 256 * 1024 * 1024;
        options.limits.max_validation_comparison_work = 512 * 1024 * 1024;
        if (comptime repeat_options.reuse) {
            options.dtd.validate.external_subset = &subset.?;
        }
        var input_buffer: [input_buffer_size]u8 = undefined;
        var file_reader = file.reader(init.io, &input_buffer);
        var reader = try xml.Reader.init(
            init.gpa,
            .{ .stream = &file_reader.interface },
            options,
        );
        defer reader.deinit();
        while (try reader.next()) |event| try totals.observe(event);
    }

    var output_buffer: [192]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output_file.interface.print(
        "{{\"repetitions\":{d},\"elements\":{d},\"attributes\":{d},\"text_bytes\":{d},\"checksum\":\"{x:0>16}\"}}\n",
        .{ repetitions, totals.elements, totals.attributes, totals.text_bytes, totals.checksum },
    );
    try output_file.interface.flush();
    return 0;
}
