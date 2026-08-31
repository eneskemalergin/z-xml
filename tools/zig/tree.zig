//! Builds and traverses the public owned Document for correctness and measurement.
//!
//! Input uses a bounded stream and DTD rejection. Raw-name mode keeps a Reader-compatible checksum
//! separate from one that also covers comments and processing instructions. Namespace mode also
//! fingerprints retained declarations and expanded names. Construction timing includes file
//! opening, input reading, parsing, owned Document creation, deinitialization, and result output;
//! traversal timing remains separate. Memory mode reports Document storage, allocation work, an
//! independent Reader-only pass, caller input storage, traversal scratch, and cleanup.

const std = @import("std");
const xml = @import("z_xml");
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const INPUT_BUFFER_SIZE = 64 * 1024;

const Mode = enum {
    summary,
    construction,
    timing,
    memory,
};

const Options = struct {
    mode: Mode = .summary,
    namespaces: bool = false,
    path: []const u8,
};

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
    namespace_declarations: u64 = 0,
    common_checksum: u64 = 14695981039346656037,
    traversal_checksum: u64 = 14695981039346656037,
    expanded_name_checksum: u64 = 14695981039346656037,

    fn sharedBytes(self: *Stats, comptime include_common: bool, value: []const u8) void {
        for (value) |byte| {
            if (include_common) {
                self.common_checksum ^= byte;
                self.common_checksum *%= 1099511628211;
            }
            self.traversal_checksum ^= byte;
            self.traversal_checksum *%= 1099511628211;
        }
    }

    fn sharedMarker(self: *Stats, comptime include_common: bool, value: u8) void {
        self.sharedBytes(include_common, &.{value});
    }

    fn traversalBytes(self: *Stats, value: []const u8) void {
        for (value) |byte| {
            self.traversal_checksum ^= byte;
            self.traversal_checksum *%= 1099511628211;
        }
    }

    fn traversalMarker(self: *Stats, value: u8) void {
        self.traversalBytes(&.{value});
    }

    fn expandedBytes(self: *Stats, value: []const u8) void {
        for (value) |byte| {
            self.expanded_name_checksum ^= byte;
            self.expanded_name_checksum *%= 1099511628211;
        }
    }

    fn expandedMarker(self: *Stats, value: u8) void {
        self.expandedBytes(&.{value});
    }

    fn expandedName(self: *Stats, value: xml.Name) void {
        const expanded = value.expanded.?;
        self.expandedMarker(7);
        self.expandedBytes(expanded.namespace_uri orelse "");
        self.expandedMarker(8);
        self.expandedBytes(expanded.local);
        self.expandedMarker(9);
        self.expandedBytes(expanded.prefix orelse "");
    }
};

const ReaderMemory = struct {
    requested_bytes: u64,
    temporary_bytes: u64,
    peak_bytes: usize,
    retained_bytes: usize,
    allocator_operations: u64,
    live_after_deinit_bytes: usize,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-tree: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args) orelse {
        std.debug.print(
            "usage: z-xml-tree [--construction|--memory|--timing] " ++
                "[--namespaces=process] FILE\n",
            .{},
        );
        return 64;
    };

    const report_memory = options.mode == .memory;
    const report_timing = options.mode == .timing;
    const build_start = std.Io.Clock.awake.now(init.io);
    const file = try std.Io.Dir.cwd().openFile(init.io, options.path, .{});
    defer file.close(init.io);
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var tracking: TrackingAllocator = .{ .child = init.gpa };
    var diagnostic: DiagnosticCapture = .{};
    var document = xml.parseDocument(
        if (report_memory) tracking.allocator() else init.gpa,
        .{ .stream = &file_reader.interface },
        .{ .reader = .{
            .namespaces = if (options.namespaces) .process else .raw,
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
    var document_live = true;
    defer if (document_live) document.deinit();
    const build_end = std.Io.Clock.awake.now(init.io);

    if (options.mode == .construction) {
        document.deinit();
        document_live = false;
        var output_buffer: [64]u8 = undefined;
        var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
        try output_file.interface.writeAll("{\"constructed\":true}\n");
        try output_file.interface.flush();
        return 0;
    }

    var stats: Stats = .{};
    var owned_memory: xml.DocumentMemoryUsage = undefined;
    var active_owned_bytes: usize = 0;
    var construction_temporary_bytes: u64 = 0;
    var reader_memory: ReaderMemory = undefined;
    var traversal_peak: usize = 0;
    var traversal_allocator_operations: u64 = 0;
    var traversal_live_after_deinit: usize = 0;
    const traversal_start = std.Io.Clock.awake.now(init.io);
    if (report_memory) {
        owned_memory = document.memoryUsage();
        if (tracking.live_bytes != owned_memory.total_capacity_bytes)
            return error.InvalidDocumentMemoryReport;
        var traversal_tracking: TrackingAllocator = .{ .child = init.gpa };
        try traverse(false, options.namespaces, traversal_tracking.allocator(), &document, &stats);
        if (traversal_tracking.live_bytes != 0) return error.TraversalMemoryLeak;
        traversal_peak = traversal_tracking.peak_live_bytes;
        traversal_allocator_operations = traversal_tracking.allocs +
            traversal_tracking.resizes + traversal_tracking.remaps;
        traversal_live_after_deinit = traversal_tracking.live_bytes;
        active_owned_bytes = try activeDocumentBytes(owned_memory, stats);
        if (active_owned_bytes > owned_memory.total_capacity_bytes or
            tracking.requested_bytes < owned_memory.total_capacity_bytes)
        {
            return error.InvalidDocumentMemoryReport;
        }
        construction_temporary_bytes = tracking.requested_bytes -
            owned_memory.total_capacity_bytes;
        reader_memory = try auditReaderMemory(init, options);
    } else if (report_timing) {
        try traverse(false, options.namespaces, init.gpa, &document, &stats);
    } else {
        try traverse(true, options.namespaces, init.gpa, &document, &stats);
    }
    const traversal_end = std.Io.Clock.awake.now(init.io);
    document.deinit();
    document_live = false;
    const live_after_deinit = if (report_memory) tracking.live_bytes else 0;
    if (live_after_deinit != 0) return error.DocumentMemoryLeak;
    var output_buffer: [1024]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    if (report_memory) {
        try output.print(
            "{{\"nodes\":{d},\"attributes\":{d},\"namespace_declarations\":{d}," ++
                "\"string_bytes\":{d},\"node_capacity_bytes\":{d}," ++
                "\"attribute_capacity_bytes\":{d}," ++
                "\"namespace_declaration_capacity_bytes\":{d}," ++
                "\"string_capacity_bytes\":{d},\"metadata_capacity_bytes\":{d}," ++
                "\"active_owned_bytes\":{d},\"growth_slack_bytes\":{d}," ++
                "\"retained_capacity_bytes\":{d}," ++
                "\"construction_requested_bytes\":{d}," ++
                "\"construction_temporary_bytes\":{d}," ++
                "\"construction_peak_bytes\":{d}," ++
                "\"construction_allocator_operations\":{d}," ++
                "\"reader_requested_bytes\":{d},\"reader_temporary_bytes\":{d}," ++
                "\"reader_peak_bytes\":{d},\"reader_retained_bytes\":{d}," ++
                "\"reader_allocator_operations\":{d}," ++
                "\"reader_live_after_deinit_bytes\":{d}," ++
                "\"caller_input_storage_bytes\":{d}," ++
                "\"traversal_scratch_peak_bytes\":{d}," ++
                "\"traversal_allocator_operations\":{d}," ++
                "\"traversal_live_after_deinit_bytes\":{d}," ++
                "\"live_after_deinit_bytes\":{d}}}\n",
            .{
                owned_memory.node_count,
                owned_memory.attribute_count,
                owned_memory.namespace_declaration_count,
                owned_memory.string_bytes,
                owned_memory.node_capacity_bytes,
                owned_memory.attribute_capacity_bytes,
                owned_memory.namespace_declaration_capacity_bytes,
                owned_memory.string_capacity_bytes,
                owned_memory.metadata_capacity_bytes,
                active_owned_bytes,
                owned_memory.total_capacity_bytes - active_owned_bytes,
                owned_memory.total_capacity_bytes,
                tracking.requested_bytes,
                construction_temporary_bytes,
                tracking.peak_live_bytes,
                tracking.allocs + tracking.resizes + tracking.remaps,
                reader_memory.requested_bytes,
                reader_memory.temporary_bytes,
                reader_memory.peak_bytes,
                reader_memory.retained_bytes,
                reader_memory.allocator_operations,
                reader_memory.live_after_deinit_bytes,
                INPUT_BUFFER_SIZE,
                traversal_peak,
                traversal_allocator_operations,
                traversal_live_after_deinit,
                live_after_deinit,
            },
        );
    } else if (report_timing) {
        try output.print(
            "{{\"build_ns\":{d},\"traversal_ns\":{d},\"elements\":{d},\"checksum\":\"{x:0>16}\"}}\n",
            .{
                build_start.durationTo(build_end).nanoseconds,
                traversal_start.durationTo(traversal_end).nanoseconds,
                stats.elements,
                stats.traversal_checksum,
            },
        );
    } else if (options.namespaces) {
        try output.print(
            "{{\"nodes\":{d},\"elements\":{d},\"attributes\":{d}," ++
                "\"text_nodes\":{d},\"text_bytes\":{d},\"comments\":{d}," ++
                "\"processing_instructions\":{d},\"namespace_declarations\":{d}," ++
                "\"max_depth\":{d},\"common_checksum\":\"{x:0>16}\"," ++
                "\"expanded_name_checksum\":\"{x:0>16}\"," ++
                "\"traversal_checksum\":\"{x:0>16}\"}}\n",
            .{
                stats.nodes,
                stats.elements,
                stats.attributes,
                stats.text_nodes,
                stats.text_bytes,
                stats.comments,
                stats.processing_instructions,
                stats.namespace_declarations,
                stats.max_depth,
                stats.common_checksum,
                stats.expanded_name_checksum,
                stats.traversal_checksum,
            },
        );
    } else {
        try output.print(
            "{{\"nodes\":{d},\"elements\":{d},\"attributes\":{d}," ++
                "\"text_nodes\":{d},\"text_bytes\":{d},\"comments\":{d}," ++
                "\"processing_instructions\":{d},\"max_depth\":{d}," ++
                "\"common_checksum\":\"{x:0>16}\"," ++
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
                stats.common_checksum,
                stats.traversal_checksum,
            },
        );
    }
    try output.flush();
    return 0;
}

fn parseOptions(args: []const []const u8) ?Options {
    var mode: Mode = .summary;
    var mode_set = false;
    var namespaces = false;
    var path: ?[]const u8 = null;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--construction") or
            std.mem.eql(u8, argument, "--timing") or
            std.mem.eql(u8, argument, "--memory"))
        {
            if (mode_set) return null;
            mode_set = true;
            mode = if (std.mem.eql(u8, argument, "--construction"))
                .construction
            else if (std.mem.eql(u8, argument, "--timing"))
                .timing
            else
                .memory;
        } else if (std.mem.eql(u8, argument, "--namespaces=process")) {
            if (namespaces) return null;
            namespaces = true;
        } else if (std.mem.startsWith(u8, argument, "--") or path != null) {
            return null;
        } else {
            path = argument;
        }
    }
    return .{ .mode = mode, .namespaces = namespaces, .path = path orelse return null };
}

fn auditReaderMemory(init: std.process.Init, options: Options) !ReaderMemory {
    const file = try std.Io.Dir.cwd().openFile(init.io, options.path, .{});
    defer file.close(init.io);
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var tracking: TrackingAllocator = .{ .child = init.gpa };
    var reader = try xml.Reader.init(
        tracking.allocator(),
        .{ .stream = &file_reader.interface },
        .{
            .namespaces = if (options.namespaces) .process else .raw,
            .dtd = .reject,
            .track_lines = false,
            .limits = .{ .max_depth = 2_048 },
        },
    );
    var reader_live = true;
    defer if (reader_live) reader.deinit();
    while (try reader.next()) |_| {}
    const retained_bytes = tracking.live_bytes;
    if (tracking.requested_bytes < retained_bytes) return error.InvalidReaderMemoryReport;
    const result: ReaderMemory = .{
        .requested_bytes = tracking.requested_bytes,
        .temporary_bytes = tracking.requested_bytes - retained_bytes,
        .peak_bytes = tracking.peak_live_bytes,
        .retained_bytes = retained_bytes,
        .allocator_operations = tracking.allocs + tracking.resizes + tracking.remaps,
        .live_after_deinit_bytes = 0,
    };
    reader.deinit();
    reader_live = false;
    if (tracking.live_bytes != 0) return error.ReaderMemoryLeak;
    return result;
}

fn activeDocumentBytes(memory: xml.DocumentMemoryUsage, stats: Stats) !usize {
    var total = try multiply(memory.node_count, @sizeOf(documentListItem("nodes")));
    total = try add(total, try multiply(stats.elements, @sizeOf(documentListItem("elements"))));
    total = try add(total, try multiply(stats.text_nodes, @sizeOf(documentListItem("texts"))));
    total = try add(total, try multiply(stats.comments, @sizeOf(documentListItem("comments"))));
    total = try add(total, try multiply(
        stats.processing_instructions,
        @sizeOf(documentListItem("processing_instructions")),
    ));
    total = try add(total, try multiply(
        memory.attribute_count,
        @sizeOf(documentListItem("attributes_storage")),
    ));
    total = try add(total, try multiply(
        memory.namespace_declaration_count,
        @sizeOf(documentListItem("namespace_storage")),
    ));
    return add(total, memory.string_bytes);
}

fn documentListItem(comptime field_name: []const u8) type {
    const List = @FieldType(xml.Document, field_name);
    return std.meta.Elem(@FieldType(List, "items"));
}

fn multiply(count: anytype, size: usize) !usize {
    const value = std.math.cast(usize, count) orelse return error.DocumentMemoryOverflow;
    return std.math.mul(usize, value, size) catch error.DocumentMemoryOverflow;
}

fn add(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right) catch error.DocumentMemoryOverflow;
}

const Frame = struct {
    node: xml.Node,
    children: xml.Document.ChildIterator,
    depth: u64,
};

fn traverse(
    comptime include_common: bool,
    namespaces: bool,
    allocator: std.mem.Allocator,
    document: *const xml.Document,
    stats: *Stats,
) !void {
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
            enter(include_common, namespaces, document, child, depth, stats);
            if (document.nodeKind(child).? == .element) {
                try stack.append(allocator, .{
                    .node = child,
                    .children = document.children(child),
                    .depth = depth,
                });
            }
        } else {
            const node = stack.pop().?.node;
            if (node != document.root()) leave(include_common, namespaces, document, node, stats);
        }
    }
}

fn enter(
    comptime include_common: bool,
    namespaces: bool,
    document: *const xml.Document,
    index: xml.Node,
    depth: u64,
    stats: *Stats,
) void {
    stats.nodes += 1;
    switch (document.nodeKind(index).?) {
        .element => {
            stats.elements += 1;
            stats.max_depth = @max(stats.max_depth, depth);
            if (namespaces) {
                var declarations = document.namespaceDeclarations(index);
                while (declarations.next()) |declaration| {
                    stats.namespace_declarations += 1;
                    stats.expandedMarker(5);
                    stats.expandedBytes(declaration.prefix orelse "");
                    stats.expandedMarker(6);
                    stats.expandedBytes(declaration.namespace_uri);
                }
                stats.expandedMarker(1);
                stats.expandedName(document.nodeName(index).?);
            }
            stats.sharedMarker(include_common, 1);
            stats.sharedBytes(include_common, document.nodeName(index).?.raw);
            var attributes = document.attributes(index);
            while (attributes.next()) |attribute| {
                stats.attributes += 1;
                stats.sharedMarker(include_common, 2);
                stats.sharedBytes(include_common, attribute.name.raw);
                stats.sharedMarker(include_common, 3);
                stats.sharedBytes(include_common, attribute.value);
                if (namespaces) {
                    stats.expandedMarker(2);
                    stats.expandedName(attribute.name);
                    stats.expandedMarker(3);
                    stats.expandedBytes(attribute.value);
                }
            }
        },
        .text => {
            const value = document.nodeValue(index).?;
            stats.text_nodes += 1;
            stats.text_bytes += value.len;
            stats.sharedBytes(include_common, value);
            if (namespaces) stats.expandedBytes(value);
        },
        .comment => {
            stats.comments += 1;
            stats.traversalMarker(5);
            stats.traversalBytes(document.nodeValue(index).?);
            stats.traversalMarker(6);
        },
        .processing_instruction => {
            stats.processing_instructions += 1;
            const value = document.processingInstruction(index).?;
            stats.traversalMarker(7);
            stats.traversalBytes(value.target);
            stats.traversalMarker(8);
            stats.traversalBytes(value.data);
            stats.traversalMarker(9);
        },
        .document => unreachable,
    }
}

fn leave(
    comptime include_common: bool,
    namespaces: bool,
    document: *const xml.Document,
    index: xml.Node,
    stats: *Stats,
) void {
    if (document.nodeKind(index).? != .element) return;
    if (namespaces) {
        stats.expandedMarker(4);
        stats.expandedName(document.nodeName(index).?);
    }
    stats.sharedMarker(include_common, 4);
    stats.sharedBytes(include_common, document.nodeName(index).?.raw);
}

// --- Tests ---

test "[unit] - [document adapter]: reports retained node kinds and values" {
    var document = try xml.parseDocument(
        std.testing.allocator,
        .{ .slice = "<r a='1'>x<!--c--><?p d?><n/></r>" },
        .{ .reader = .{ .namespaces = .raw, .dtd = .reject } },
    );
    defer document.deinit();
    var stats: Stats = .{};
    try traverse(true, false, std.testing.allocator, &document, &stats);
    try std.testing.expectEqual(@as(u64, 6), stats.nodes);
    try std.testing.expectEqual(@as(u64, 2), stats.elements);
    try std.testing.expectEqual(@as(u64, 1), stats.attributes);
    try std.testing.expectEqual(@as(u64, 1), stats.text_nodes);
    try std.testing.expectEqual(@as(u64, 1), stats.text_bytes);
    try std.testing.expectEqual(@as(u64, 1), stats.comments);
    try std.testing.expectEqual(@as(u64, 1), stats.processing_instructions);
    try std.testing.expectEqual(@as(u64, 2), stats.max_depth);
    try std.testing.expectEqual(@as(u64, 0x804252a17ef54766), stats.common_checksum);
    try std.testing.expectEqual(@as(u64, 0x7b0ab72bea31905e), stats.traversal_checksum);

    var changed = try xml.parseDocument(
        std.testing.allocator,
        .{ .slice = "<r a='1'>x<!--d--><?p e?><n/></r>" },
        .{ .reader = .{ .namespaces = .raw, .dtd = .reject } },
    );
    defer changed.deinit();
    var changed_stats: Stats = .{};
    try traverse(true, false, std.testing.allocator, &changed, &changed_stats);
    try std.testing.expectEqual(stats.common_checksum, changed_stats.common_checksum);
    try std.testing.expect(stats.traversal_checksum != changed_stats.traversal_checksum);
}

test "[unit] - [document adapter]: fingerprints retained namespace data" {
    var document = try xml.parseDocument(
        std.testing.allocator,
        .{ .slice = "<root><p:n xmlns:p='urn:a' p:a='v'/></root>" },
        .{ .reader = .{ .namespaces = .process, .dtd = .reject } },
    );
    defer document.deinit();
    var stats: Stats = .{};
    try traverse(true, true, std.testing.allocator, &document, &stats);
    try std.testing.expectEqual(@as(u64, 1), stats.namespace_declarations);
    try std.testing.expectEqual(@as(u64, 0x9de0595931a6a17c), stats.expanded_name_checksum);
}
