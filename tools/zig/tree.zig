//! Owned-tree common-summary adapter for matched DOM measurements.

const std = @import("std");
const xml = @import("z_xml");

const CONFIG = xml.Configs.XML10_UTF8_NO_DTD_FAST;
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
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-tree: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const report_memory = args.len == 3 and std.mem.eql(u8, args[1], "--memory");
    const report_timing = args.len == 3 and std.mem.eql(u8, args[1], "--timing");
    if (args.len != 2 and !report_memory and !report_timing) {
        std.debug.print("usage: z-xml-tree [--memory|--timing] FILE\n", .{});
        return 64;
    }

    const input_path = args[if (report_memory or report_timing) 2 else 1];
    const file = try std.Io.Dir.cwd().openFile(init.io, input_path, .{});
    defer file.close(init.io);
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var pull = try xml.ProfileIoReader(CONFIG).init(init.gpa, .{}, &file_reader.interface);
    defer pull.deinit();
    const build_start = std.Io.Clock.awake.now(init.io);
    var document = xml.buildProfileTreeFromPull(CONFIG, init.gpa, .{}, &pull) catch |err| {
        if (pull.diagnostic()) |diagnostic| {
            std.debug.print(
                "z-xml-tree: {s} at source {d} byte {d}\n",
                .{
                    @tagName(diagnostic.code),
                    diagnostic.primary.source_id,
                    diagnostic.primary.byte_offset,
                },
            );
        }
        return switch (err) {
            error.InvalidXml, error.InvalidDtd, error.NotValid => 2,
            error.LimitExceeded, error.TreeLimit, error.OutOfMemory => 3,
            else => err,
        };
    };
    defer document.deinit();
    const build_end = std.Io.Clock.awake.now(init.io);

    var stats: Stats = .{};
    if (!report_memory) traverse(&document, &stats);
    const traversal_end = std.Io.Clock.awake.now(init.io);
    var output_buffer: [160]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    if (report_memory) {
        const memory = document.memoryUsage();
        try output.print(
            "{{\"nodes\":{d},\"attributes\":{d},\"strings\":{d},\"owned_capacity\":{d}}}\n",
            .{
                memory.node_count,
                memory.attribute_count,
                memory.string_bytes,
                memory.total_capacity_bytes,
            },
        );
    } else if (report_timing) {
        try output.print(
            "{{\"build_ns\":{d},\"traversal_ns\":{d},\"elements\":{d},\"checksum\":\"{x:0>16}\"}}\n",
            .{
                build_start.durationTo(build_end).nanoseconds,
                build_end.durationTo(traversal_end).nanoseconds,
                stats.elements,
                stats.checksum,
            },
        );
    } else try output.print(
        "{{\"elements\":{d},\"attributes\":{d},\"text_bytes\":{d},\"checksum\":\"{x:0>16}\"}}\n",
        .{ stats.elements, stats.attributes, stats.text_bytes, stats.checksum },
    );
    try output.flush();
    return 0;
}

fn traverse(document: *const xml.ProfileDocumentFor(CONFIG), stats: *Stats) void {
    var index = document.firstChild(document.root());
    while (index != 0) {
        enter(document, index, stats);
        const child = document.firstChild(index);
        if (child != 0) {
            index = child;
            continue;
        }
        while (index != 0) {
            leave(document, index, stats);
            const sibling = document.nextSibling(index);
            if (sibling != 0) {
                index = sibling;
                break;
            }
            index = document.parent(index);
            if (index == document.root()) return;
        }
    }
}

fn enter(document: *const xml.ProfileDocumentFor(CONFIG), index: xml.Node, stats: *Stats) void {
    switch (document.nodeKind(index).?) {
        .element => {
            stats.elements += 1;
            stats.marker(1);
            stats.bytes(document.nodeName(index).?.raw);
            var attribute_index: usize = 0;
            while (attribute_index < document.attributeCount(index)) : (attribute_index += 1) {
                const attribute = document.attributeAt(index, attribute_index).?;
                stats.attributes += 1;
                stats.marker(2);
                stats.bytes(attribute.name.raw);
                stats.marker(3);
                stats.bytes(attribute.value);
            }
        },
        .text => {
            const value = document.nodeValue(index).?;
            stats.text_bytes += value.len;
            stats.bytes(value);
        },
        else => {},
    }
}

fn leave(document: *const xml.ProfileDocumentFor(CONFIG), index: xml.Node, stats: *Stats) void {
    if (document.nodeKind(index).? != .element) return;
    stats.marker(4);
    stats.bytes(document.nodeName(index).?.raw);
}
