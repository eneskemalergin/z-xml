//! Builds and traverses the public owned Document for correctness and measurement.
//!
//! Input uses a bounded stream and DTD rejection. Raw-name mode keeps a Reader-compatible checksum
//! separate from one that also covers comments and processing instructions. Namespace mode also
//! fingerprints retained declarations and expanded names. Whole-process construction measurements
//! include file opening, input reading, parsing, owned Document creation, deinitialization, and
//! result output. Reported traversal timing starts after construction and ends before destruction.
//! Timing can repeat the same complete traversal after one build for profile attribution. Memory
//! mode reports Document storage, allocation work, an independent Reader-only pass, caller input
//! storage, traversal scratch, and cleanup. Repeated construction creates and destroys independent
//! public Documents over fixed single-input or large-then-small schedules.

const std = @import("std");
const xml = @import("z_xml");
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const INPUT_BUFFER_SIZE = 64 * 1024;

const Mode = enum {
    summary,
    construction,
    timing,
    memory,
    repeat,
};

const RepeatReport = enum {
    summary,
    verify,
    memory,
    timing,
};

const Options = struct {
    mode: Mode = .summary,
    namespaces: bool = false,
    iterations: usize = 1,
    repeat_report: RepeatReport = .summary,
    next_path: ?[]const u8 = null,
    next_iterations: usize = 0,
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

const RepeatPhase = struct {
    documents: usize,
    input_bytes: u64,
    guard: u64 = 0,
    retained_capacity_bytes: usize = 0,
    retained_capacity_total_bytes: u64 = 0,
    elements: u64 = 0,
    attributes: u64 = 0,
    text_bytes: u64 = 0,
    common_checksum: u64 = 0,
    parse_requested_bytes: u64 = 0,
    parse_temporary_bytes: u64 = 0,
    parse_peak_live_bytes: usize = 0,
    parse_allocator_operations: u64 = 0,
    parse_live_after_deinit_bytes: usize = 0,
    reader_requested_bytes: u64 = 0,
    reader_temporary_bytes: u64 = 0,
    reader_peak_live_bytes: usize = 0,
    reader_allocator_operations: u64 = 0,
    reader_live_after_deinit_bytes: usize = 0,
    parse_ns: u64 = 0,
    parse_deinit_ns: u64 = 0,
    reader_ns: u64 = 0,
    reader_deinit_ns: u64 = 0,
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
                "[--iterations=N] [--namespaces=process] FILE\n" ++
                "       z-xml-tree --repeat=N [--next-file=FILE --next-repeat=N] " ++
                "[--verify|--report-memory|--report-timing] FILE\n",
            .{},
        );
        return 64;
    };

    if (options.mode == .repeat) return runRepeated(init, options);

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
        traversal_allocator_operations = traversal_tracking.operations();
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
        for (0..options.iterations) |_| {
            stats = .{};
            try traverse(false, options.namespaces, init.gpa, &document, &stats);
        }
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
                tracking.operations(),
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
            "{{\"build_ns\":{d},\"traversal_ns\":{d},\"iterations\":{d}," ++
                "\"elements\":{d},\"checksum\":\"{x:0>16}\"}}\n",
            .{
                build_start.durationTo(build_end).nanoseconds,
                traversal_start.durationTo(traversal_end).nanoseconds,
                options.iterations,
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
    var iterations: usize = 1;
    var iterations_set = false;
    var repeat_report: RepeatReport = .summary;
    var repeat_report_set = false;
    var next_path: ?[]const u8 = null;
    var next_iterations: usize = 0;
    var next_iterations_set = false;
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
        } else if (std.mem.startsWith(u8, argument, "--repeat=")) {
            if (mode_set or iterations_set) return null;
            mode_set = true;
            mode = .repeat;
            iterations_set = true;
            iterations = parsePositiveCount(argument["--repeat=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, argument, "--next-file=")) {
            if (next_path != null or argument.len == "--next-file=".len) return null;
            next_path = argument["--next-file=".len..];
        } else if (std.mem.startsWith(u8, argument, "--next-repeat=")) {
            if (next_iterations_set) return null;
            next_iterations_set = true;
            next_iterations = parsePositiveCount(
                argument["--next-repeat=".len..],
            ) orelse return null;
        } else if (std.mem.eql(u8, argument, "--verify") or
            std.mem.eql(u8, argument, "--report-memory") or
            std.mem.eql(u8, argument, "--report-timing"))
        {
            if (repeat_report_set) return null;
            repeat_report_set = true;
            repeat_report = if (std.mem.eql(u8, argument, "--verify"))
                .verify
            else if (std.mem.eql(u8, argument, "--report-memory"))
                .memory
            else
                .timing;
        } else if (std.mem.startsWith(u8, argument, "--iterations=")) {
            if (iterations_set) return null;
            iterations_set = true;
            iterations = std.fmt.parseInt(
                usize,
                argument["--iterations=".len..],
                10,
            ) catch return null;
            if (iterations == 0) return null;
        } else if (std.mem.startsWith(u8, argument, "--") or path != null) {
            return null;
        } else {
            path = argument;
        }
    }
    if (mode == .repeat) {
        if (!iterations_set or namespaces) return null;
        if ((next_path != null) != next_iterations_set) return null;
    } else if (iterations_set and mode != .timing) {
        return null;
    } else if (repeat_report_set or next_path != null or next_iterations_set) {
        return null;
    }
    return .{
        .mode = mode,
        .namespaces = namespaces,
        .iterations = iterations,
        .repeat_report = repeat_report,
        .next_path = next_path,
        .next_iterations = next_iterations,
        .path = path orelse return null,
    };
}

fn parsePositiveCount(value: []const u8) ?usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return null;
    return if (count == 0 or count > 1_000_000) null else count;
}

fn runRepeated(init: std.process.Init, options: Options) !u8 {
    const primary = try runRepeatPhase(
        init,
        options.path,
        options.iterations,
        options.repeat_report,
    );
    const next_path = if (options.next_path) |path|
        if (std.fs.path.isAbsolute(path))
            path
        else
            try std.fs.path.resolve(
                init.arena.allocator(),
                &.{ std.fs.path.dirname(options.path) orelse ".", path },
            )
    else
        null;
    const next = if (next_path) |path|
        try runRepeatPhase(init, path, options.next_iterations, options.repeat_report)
    else
        null;

    var primary_with_reader = primary;
    var next_with_reader = next;
    if (options.repeat_report == .memory or options.repeat_report == .timing) {
        try auditRepeatedReader(
            init,
            options.path,
            options.iterations,
            options.repeat_report,
            &primary_with_reader,
        );
        if (next_path) |path| {
            try auditRepeatedReader(
                init,
                path,
                options.next_iterations,
                options.repeat_report,
                &next_with_reader.?,
            );
        }
    }

    var output_buffer: [4096]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    try output.print("{{\"mode\":\"{s}\",\"primary\":", .{@tagName(options.repeat_report)});
    try writeRepeatPhase(output, primary_with_reader, options.repeat_report);
    try output.writeAll(",\"next\":");
    if (next_with_reader) |phase| {
        try writeRepeatPhase(output, phase, options.repeat_report);
    } else {
        try output.writeAll("null");
    }
    try output.print(
        ",\"total_documents\":{d},\"caller_input_storage_bytes\":{d}," ++
            "\"live_after_deinit_bytes\":0}}\n",
        .{ options.iterations + options.next_iterations, INPUT_BUFFER_SIZE },
    );
    try output.flush();
    return 0;
}

fn runRepeatPhase(
    init: std.process.Init,
    path: []const u8,
    documents: usize,
    report: RepeatReport,
) !RepeatPhase {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var tracking: TrackingAllocator = .{ .child = init.gpa };
    const allocator = if (report == .memory) tracking.allocator() else init.gpa;
    var result: RepeatPhase = .{ .documents = documents, .input_bytes = stat.size };
    var retained_capacity: ?usize = null;
    var expected_stats: ?Stats = null;

    for (0..documents) |_| {
        try file_reader.seekTo(0);
        var diagnostic: DiagnosticCapture = .{};
        const parse_start = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        var document = try xml.parseDocument(
            allocator,
            .{ .stream = &file_reader.interface },
            .{ .reader = .{
                .namespaces = .raw,
                .dtd = .reject,
                .track_lines = false,
                .diagnostic_sink = diagnostic.sink(),
                .limits = .{ .max_depth = 2_048 },
            } },
        );
        var document_live = true;
        defer if (document_live) document.deinit();
        const parse_end = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        const memory = document.memoryUsage();
        if (retained_capacity) |expected| {
            if (expected != memory.total_capacity_bytes) return error.RepeatDocumentDrift;
        } else {
            retained_capacity = memory.total_capacity_bytes;
        }
        result.retained_capacity_total_bytes = std.math.add(
            u64,
            result.retained_capacity_total_bytes,
            memory.total_capacity_bytes,
        ) catch return error.DocumentMemoryOverflow;
        var document_guard: u64 = 14695981039346656037;
        hashRepeatMemory(&document_guard, memory);
        if (result.guard == 0) {
            result.guard = document_guard;
        } else if (result.guard != document_guard) {
            return error.RepeatDocumentDrift;
        }
        if (report == .verify) {
            var stats: Stats = .{};
            try traverse(true, false, init.gpa, &document, &stats);
            if (expected_stats) |expected| {
                if (!std.meta.eql(expected, stats)) return error.RepeatDocumentDrift;
            } else {
                expected_stats = stats;
            }
        }
        if (report == .memory and tracking.live_bytes != memory.total_capacity_bytes)
            return error.InvalidDocumentMemoryReport;
        const deinit_start = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        document.deinit();
        document_live = false;
        const deinit_end = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        if (report == .memory and tracking.live_bytes != 0) return error.DocumentMemoryLeak;
        if (report == .timing) {
            result.parse_ns = try addNanoseconds(result.parse_ns, parse_start, parse_end);
            result.parse_deinit_ns = try addNanoseconds(
                result.parse_deinit_ns,
                deinit_start,
                deinit_end,
            );
        }
    }

    result.retained_capacity_bytes = retained_capacity orelse 0;
    if (expected_stats) |stats| {
        result.elements = stats.elements;
        result.attributes = stats.attributes;
        result.text_bytes = stats.text_bytes;
        result.common_checksum = stats.common_checksum;
    }
    if (report == .memory) {
        if (tracking.requested_bytes < result.retained_capacity_total_bytes)
            return error.InvalidDocumentMemoryReport;
        result.parse_requested_bytes = tracking.requested_bytes;
        result.parse_temporary_bytes = tracking.requested_bytes -
            result.retained_capacity_total_bytes;
        result.parse_peak_live_bytes = tracking.peak_live_bytes;
        result.parse_allocator_operations = tracking.operations();
        result.parse_live_after_deinit_bytes = tracking.live_bytes;
    }
    return result;
}

fn auditRepeatedReader(
    init: std.process.Init,
    path: []const u8,
    documents: usize,
    report: RepeatReport,
    result: *RepeatPhase,
) !void {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var tracking: TrackingAllocator = .{ .child = init.gpa };
    const allocator = if (report == .memory) tracking.allocator() else init.gpa;
    var retained_total: u64 = 0;

    for (0..documents) |_| {
        try file_reader.seekTo(0);
        const read_start = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        var reader = try xml.Reader.init(
            allocator,
            .{ .stream = &file_reader.interface },
            .{
                .namespaces = .raw,
                .dtd = .reject,
                .track_lines = false,
                .limits = .{ .max_depth = 2_048 },
            },
        );
        var reader_live = true;
        defer if (reader_live) reader.deinit();
        while (try reader.next()) |_| {}
        const read_end = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        if (report == .memory) {
            retained_total = std.math.add(u64, retained_total, tracking.live_bytes) catch
                return error.DocumentMemoryOverflow;
        }
        const deinit_start = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        reader.deinit();
        reader_live = false;
        const deinit_end = if (report == .timing) std.Io.Clock.awake.now(init.io) else undefined;
        if (report == .memory and tracking.live_bytes != 0) return error.ReaderMemoryLeak;
        if (report == .timing) {
            result.reader_ns = try addNanoseconds(result.reader_ns, read_start, read_end);
            result.reader_deinit_ns = try addNanoseconds(
                result.reader_deinit_ns,
                deinit_start,
                deinit_end,
            );
        }
    }

    if (report == .memory) {
        if (tracking.requested_bytes < retained_total) return error.InvalidReaderMemoryReport;
        result.reader_requested_bytes = tracking.requested_bytes;
        result.reader_temporary_bytes = tracking.requested_bytes - retained_total;
        result.reader_peak_live_bytes = tracking.peak_live_bytes;
        result.reader_allocator_operations = tracking.operations();
        result.reader_live_after_deinit_bytes = tracking.live_bytes;
    }
}

fn hashRepeatMemory(hash: *u64, memory: xml.DocumentMemoryUsage) void {
    inline for (.{
        memory.node_count,
        memory.attribute_count,
        memory.namespace_declaration_count,
        memory.string_bytes,
        memory.node_capacity_bytes,
        memory.attribute_capacity_bytes,
        memory.namespace_declaration_capacity_bytes,
        memory.string_capacity_bytes,
        memory.metadata_capacity_bytes,
        memory.total_capacity_bytes,
    }) |value| {
        var remaining: u64 = @intCast(value);
        for (0..8) |_| {
            hash.* ^= @truncate(remaining);
            hash.* *%= 1099511628211;
            remaining >>= 8;
        }
    }
}

fn addNanoseconds(
    total: u64,
    start: std.Io.Timestamp,
    end: std.Io.Timestamp,
) !u64 {
    const elapsed = std.math.cast(u64, start.durationTo(end).nanoseconds) orelse
        return error.TimingOverflow;
    return std.math.add(u64, total, elapsed) catch
        error.TimingOverflow;
}

fn writeRepeatPhase(
    output: *std.Io.Writer,
    phase: RepeatPhase,
    report: RepeatReport,
) !void {
    try output.print(
        "{{\"documents\":{d},\"input_bytes\":{d},\"guard\":\"{x:0>16}\"," ++
            "\"retained_capacity_bytes\":{d},\"retained_capacity_total_bytes\":{d}",
        .{
            phase.documents,
            phase.input_bytes,
            phase.guard,
            phase.retained_capacity_bytes,
            phase.retained_capacity_total_bytes,
        },
    );
    switch (report) {
        .summary => {},
        .verify => try output.print(
            ",\"elements\":{d},\"attributes\":{d},\"text_bytes\":{d}," ++
                "\"common_checksum\":\"{x:0>16}\"",
            .{ phase.elements, phase.attributes, phase.text_bytes, phase.common_checksum },
        ),
        .memory => try output.print(
            ",\"parse_requested_bytes\":{d},\"parse_temporary_bytes\":{d}," ++
                "\"parse_peak_live_bytes\":{d},\"parse_allocator_operations\":{d}," ++
                "\"parse_live_after_deinit_bytes\":{d}," ++
                "\"reader_requested_bytes\":{d},\"reader_temporary_bytes\":{d}," ++
                "\"reader_peak_live_bytes\":{d},\"reader_allocator_operations\":{d}," ++
                "\"reader_live_after_deinit_bytes\":{d}",
            .{
                phase.parse_requested_bytes,
                phase.parse_temporary_bytes,
                phase.parse_peak_live_bytes,
                phase.parse_allocator_operations,
                phase.parse_live_after_deinit_bytes,
                phase.reader_requested_bytes,
                phase.reader_temporary_bytes,
                phase.reader_peak_live_bytes,
                phase.reader_allocator_operations,
                phase.reader_live_after_deinit_bytes,
            },
        ),
        .timing => try output.print(
            ",\"parse_ns\":{d},\"parse_deinit_ns\":{d}," ++
                "\"reader_ns\":{d},\"reader_deinit_ns\":{d}",
            .{ phase.parse_ns, phase.parse_deinit_ns, phase.reader_ns, phase.reader_deinit_ns },
        ),
    }
    try output.writeByte('}');
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
        .allocator_operations = tracking.operations(),
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

test "[unit] - [document adapter options]: accepts positive timing iterations only" {
    const options = parseOptions(&.{
        "z-xml-tree",
        "--timing",
        "--iterations=8",
        "--namespaces=process",
        "input.xml",
    }).?;
    try std.testing.expectEqual(Mode.timing, options.mode);
    try std.testing.expectEqual(@as(usize, 8), options.iterations);
    try std.testing.expect(options.namespaces);
    try std.testing.expectEqualStrings("input.xml", options.path);
    try std.testing.expect(parseOptions(&.{ "z-xml-tree", "--iterations=8", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-tree", "--timing", "--iterations=0", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-tree", "--timing", "--iterations=-1", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-tree", "--timing", "--iterations=x", "x" }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-tree",
        "--timing",
        "--iterations=2",
        "--iterations=3",
        "x",
    }) == null);
}

test "[unit] - [document adapter options]: accepts complete repeated construction schedules" {
    const options = parseOptions(&.{
        "z-xml-tree",
        "--repeat=2",
        "--next-file=small.xml",
        "--next-repeat=4096",
        "--report-memory",
        "large.xml",
    }).?;
    try std.testing.expectEqual(Mode.repeat, options.mode);
    try std.testing.expectEqual(@as(usize, 2), options.iterations);
    try std.testing.expectEqual(RepeatReport.memory, options.repeat_report);
    try std.testing.expectEqualStrings("small.xml", options.next_path.?);
    try std.testing.expectEqual(@as(usize, 4096), options.next_iterations);
    try std.testing.expectEqualStrings("large.xml", options.path);

    try std.testing.expect(parseOptions(&.{ "z-xml-tree", "--repeat=0", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-tree", "--repeat=1000001", "x" }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-tree",
        "--repeat=1",
        "--next-file=x",
        "y",
    }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-tree",
        "--repeat=1",
        "--next-repeat=1",
        "y",
    }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-tree",
        "--repeat=1",
        "--verify",
        "--report-memory",
        "x",
    }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-tree",
        "--repeat=1",
        "--namespaces=process",
        "x",
    }) == null);
}
