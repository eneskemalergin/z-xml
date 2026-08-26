//! Public Document adapter for construction, traversal, and memory measurements.

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
    nodes: u64 = 1,
    elements: u64 = 0,
    attributes: u64 = 0,
    text_nodes: u64 = 0,
    text_bytes: u64 = 0,
    comments: u64 = 0,
    processing_instructions: u64 = 0,
    max_depth: u64 = 0,
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
            .limits = .{ .max_depth = 2_048 },
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
    var traversal_peak: usize = 0;
    var traversal_allocator_operations: u64 = 0;
    if (report_memory) {
        var traversal_tracking: TrackingAllocator = .{ .child = init.gpa };
        try traverse(traversal_tracking.allocator(), &document, &stats);
        if (traversal_tracking.live_bytes != 0) return error.TraversalMemoryLeak;
        traversal_peak = traversal_tracking.peak_live_bytes;
        traversal_allocator_operations = traversal_tracking.allocs +
            traversal_tracking.resizes + traversal_tracking.remaps;
    } else {
        try traverse(init.gpa, &document, &stats);
    }
    const traversal_end = std.Io.Clock.awake.now(init.io);
    var output_buffer: [256]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    if (report_memory) {
        try output.print(
            "{{\"nodes\":{d},\"attributes\":{d},\"namespace_declarations\":{d}," ++
                "\"string_bytes\":{d},\"retained_capacity_bytes\":{d}," ++
                "\"construction_peak_bytes\":{d}," ++
                "\"construction_allocator_operations\":{d}," ++
                "\"traversal_scratch_peak_bytes\":{d}," ++
                "\"traversal_allocator_operations\":{d}}}\n",
            .{
                owned_memory.node_count,
                owned_memory.attribute_count,
                owned_memory.namespace_declaration_count,
                owned_memory.string_bytes,
                owned_memory.total_capacity_bytes,
                construction_peak,
                allocator_operations,
                traversal_peak,
                traversal_allocator_operations,
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
        "{{\"nodes\":{d},\"elements\":{d},\"attributes\":{d}," ++
            "\"text_nodes\":{d},\"text_bytes\":{d},\"comments\":{d}," ++
            "\"processing_instructions\":{d},\"max_depth\":{d}," ++
            "\"traversal_checksum\":\"{x:0>16}\"}}\n",
        .{
            stats.nodes,
            stats.elements,
            stats.attributes,
            stats.text_nodes,
            stats.text_bytes,
            stats.comments,
            stats.processing_instructions,
            stats.max_depth,
            stats.checksum,
        },
    );
    try output.flush();
    return 0;
}

const Frame = struct {
    node: xml.Node,
    children: xml.Document.ChildIterator,
    depth: u64,
};

fn traverse(allocator: std.mem.Allocator, document: *const xml.Document, stats: *Stats) !void {
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{
        .node = document.root(),
        .children = document.children(document.root()),
        .depth = 0,
    });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (frame.children.next()) |child| {
            const depth = frame.depth + 1;
            enter(document, child, depth, stats);
            if (document.nodeKind(child).? == .element) {
                try stack.append(allocator, .{
                    .node = child,
                    .children = document.children(child),
                    .depth = depth,
                });
            }
        } else {
            const node = stack.pop().?.node;
            if (node != document.root()) leave(document, node, stats);
        }
    }
}

fn enter(document: *const xml.Document, index: xml.Node, depth: u64, stats: *Stats) void {
    stats.nodes += 1;
    switch (document.nodeKind(index).?) {
        .element => {
            stats.elements += 1;
            stats.max_depth = @max(stats.max_depth, depth);
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
            stats.text_nodes += 1;
            stats.text_bytes += value.len;
            stats.bytes(value);
        },
        .comment => stats.comments += 1,
        .processing_instruction => stats.processing_instructions += 1,
        .document => unreachable,
    }
}

fn leave(document: *const xml.Document, index: xml.Node, stats: *Stats) void {
    if (document.nodeKind(index).? != .element) return;
    stats.marker(4);
    stats.bytes(document.nodeName(index).?.raw);
}

// --- Tests ---

test "[unit] - [document adapter]: reports complete traversal work" {
    var document = try xml.parseDocument(
        std.testing.allocator,
        .{ .slice = "<r a='1'>x<!--c--><?p d?><n/></r>" },
        .{ .reader = .{ .namespaces = .raw, .dtd = .reject } },
    );
    defer document.deinit();
    var stats: Stats = .{};
    try traverse(std.testing.allocator, &document, &stats);
    try std.testing.expectEqual(@as(u64, 6), stats.nodes);
    try std.testing.expectEqual(@as(u64, 2), stats.elements);
    try std.testing.expectEqual(@as(u64, 1), stats.attributes);
    try std.testing.expectEqual(@as(u64, 1), stats.text_nodes);
    try std.testing.expectEqual(@as(u64, 1), stats.text_bytes);
    try std.testing.expectEqual(@as(u64, 1), stats.comments);
    try std.testing.expectEqual(@as(u64, 1), stats.processing_instructions);
    try std.testing.expectEqual(@as(u64, 2), stats.max_depth);
    try std.testing.expectEqual(@as(u64, 0x804252a17ef54766), stats.checksum);
}
