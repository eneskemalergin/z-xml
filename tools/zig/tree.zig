//! Owned-tree common-summary adapter for matched DOM measurements.

const std = @import("std");
const xml = @import("z_xml");
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const INPUT_BUFFER_SIZE = 64 * 1024;

const DiagnosticCapture = struct {
    value: ?struct { code: xml.DiagnosticCode, primary: xml.Location } = null,

    fn sink(self: *DiagnosticCapture) xml.DiagnosticSink {
        return .{ .context = self, .report_fn = report };
    }

    fn report(context: ?*anyopaque, diagnostic: xml.Diagnostic) void {
        const self: *DiagnosticCapture = @ptrCast(@alignCast(context.?));
        self.value = .{ .code = diagnostic.code, .primary = diagnostic.primary };
    }
};

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
    var tracking: TrackingAllocator = .{ .child = init.gpa };
    var diagnostic: DiagnosticCapture = .{};
    const build_start = std.Io.Clock.awake.now(init.io);
    var document = xml.parseDocument(
        tracking.allocator(),
        .{ .stream = &file_reader.interface },
        .{ .reader = .{
            .namespaces = .raw,
            .dtd = .reject,
            .track_lines = false,
            .diagnostic_sink = diagnostic.sink(),
        } },
    ) catch |err| {
        if (diagnostic.value) |value| {
            std.debug.print(
                "z-xml-tree: {s} at source {d} byte {d}\n",
                .{ @tagName(value.code), value.primary.source_id, value.primary.byte_offset },
            );
        }
        return switch (err) {
            error.InvalidXml,
            error.UnsupportedVersion,
            error.InvalidEncoding,
            error.UnsupportedEncoding,
            error.DtdForbidden,
            error.ExternalResourceForbidden,
            error.ExternalResourceUnavailable,
            error.ExternalResourceFailed,
            error.NotNormalized,
            => 2,
            error.LimitExceeded, error.DocumentLimit, error.OutOfMemory => 3,
            else => err,
        };
    };
    defer document.deinit();
    const build_end = std.Io.Clock.awake.now(init.io);
    const owned_memory = document.memoryUsage();
    if (tracking.live_bytes != owned_memory.total_capacity_bytes)
        return error.InvalidDocumentMemoryReport;
    const construction_peak = tracking.peak_live_bytes;
    const allocator_operations = tracking.allocs + tracking.resizes + tracking.remaps;

    var stats: Stats = .{};
    if (!report_memory) try traverse(init.gpa, &document, &stats);
    const traversal_end = std.Io.Clock.awake.now(init.io);
    var output_buffer: [256]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    if (report_memory) {
        try output.print(
            "{{\"nodes\":{d},\"attributes\":{d},\"strings\":{d}," ++
                "\"owned_capacity\":{d},\"construction_peak\":{d}," ++
                "\"allocator_operations\":{d}}}\n",
            .{
                owned_memory.node_count,
                owned_memory.attribute_count,
                owned_memory.string_bytes,
                owned_memory.total_capacity_bytes,
                construction_peak,
                allocator_operations,
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

const Frame = struct {
    node: xml.Node,
    children: xml.Document.ChildIterator,
};

fn traverse(allocator: std.mem.Allocator, document: *const xml.Document, stats: *Stats) !void {
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{
        .node = document.root(),
        .children = document.children(document.root()),
    });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (frame.children.next()) |child| {
            enter(document, child, stats);
            if (document.nodeKind(child).? == .element) {
                try stack.append(allocator, .{
                    .node = child,
                    .children = document.children(child),
                });
            }
        } else {
            const node = stack.pop().?.node;
            if (node != document.root()) leave(document, node, stats);
        }
    }
}

fn enter(document: *const xml.Document, index: xml.Node, stats: *Stats) void {
    switch (document.nodeKind(index).?) {
        .element => {
            stats.elements += 1;
            stats.marker(1);
            stats.bytes(document.nodeName(index).?.raw);
            var attributes = document.attributes(index);
            while (attributes.next()) |attribute| {
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

fn leave(document: *const xml.Document, index: xml.Node, stats: *Stats) void {
    if (document.nodeKind(index).? != .element) return;
    stats.marker(4);
    stats.bytes(document.nodeName(index).?.raw);
}
