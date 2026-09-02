//! Measures repeated parsing with one compiled normal Reader configuration.
//!
//! Resident input is passed as one slice; stream input reuses a bounded file-reader buffer. The
//! adapter resets the same Reader with retained capacity between iterations and rejects any change
//! in the observed event summary. An optional second file measures a large-then-small transition
//! without replacing the Reader.
//!
//! Full consumption hashes observed event data; minimal consumption records only counters. Optional
//! timing and memory output separate source setup, Reader initialization, first and reset documents,
//! retained capacity, explicit release, and caller-owned input storage.

const std = @import("std");
const xml = @import("z_xml");
const persistent_options = @import("persistent_options");
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const ENGINE = if (persistent_options.default_options)
    "z-xml-default"
else if (persistent_options.namespaces)
    "z-xml-ns"
else
    "z-xml";
const DEFAULT_CHUNK_BYTES = 64 * 1024;

const InputModel = enum {
    resident,
    stream,
};

const Consumer = enum {
    minimal,
    full,
};

const ParserStorage = enum {
    dynamic,
    fixed,
};

const Options = struct {
    input: InputModel = .resident,
    consumer: Consumer = .full,
    iterations: usize = 1,
    next_iterations: usize = 0,
    chunk_bytes: usize = DEFAULT_CHUNK_BYTES,
    report_memory: bool = false,
    report_timing: bool = false,
    release_memory: bool = false,
    parser_storage: ParserStorage = .dynamic,
    next_path: ?[]const u8 = null,
    path: []const u8,
};

const MemoryStats = struct {
    input_bytes: u64,
    next_input_bytes: u64,
    caller_input_storage_bytes: usize,
    first_allocator_operations: u64,
    primary_warm_allocator_operations: u64,
    next_allocator_operations: u64,
    warm_allocator_operations: u64,
    release_allocator_operations: u64,
    allocator_allocs: u64,
    allocator_resizes: u64,
    allocator_remaps: u64,
    requested_bytes: u64,
    peak_live_bytes: usize,
    retained_capacity: usize,
    live_bytes_before_release: usize,
    retained_capacity_after_release: usize,
    live_bytes_after_release: usize,
    live_bytes_before_deinit: usize,
    live_bytes_after_deinit: usize,
};

const TimingStats = struct {
    source_setup_ns: i96,
    reader_init_ns: i96,
    first_document_ns: i96,
    primary_warm_ns: i96,
    next_documents_ns: i96,
    release_ns: i96,
};

const Stats = struct {
    elements: u64 = 0,
    attributes: u64 = 0,
    text_bytes: u64 = 0,
    name_bytes: u64 = 0,
    value_bytes: u64 = 0,
    fragments: u64 = 0,
    namespace_declarations: u64 = 0,
    namespace_uri_bytes: u64 = 0,
    local_name_bytes: u64 = 0,
    prefix_bytes: u64 = 0,
    accumulator: u64 = 14695981039346656037,
    consumer: Consumer,

    fn bytes(self: *Stats, value: []const u8) void {
        if (self.consumer == .minimal) return;
        for (value) |byte| {
            self.accumulator ^= byte;
            self.accumulator *%= 1099511628211;
        }
    }

    fn marker(self: *Stats, value: u8) void {
        self.bytes(&.{value});
    }

    fn name(self: *Stats, value: xml.Name) void {
        if (comptime persistent_options.namespace_summary) {
            const expanded = value.expanded.?;
            const namespace_uri = expanded.namespace_uri orelse "";
            const prefix = expanded.prefix orelse "";
            self.namespace_uri_bytes += namespace_uri.len;
            self.local_name_bytes += expanded.local.len;
            self.prefix_bytes += prefix.len;
            self.marker(7);
            self.bytes(namespace_uri);
            self.marker(8);
            self.bytes(expanded.local);
            self.marker(9);
            self.bytes(prefix);
        } else {
            self.bytes(value.raw);
        }
    }

    fn observe(self: *Stats, event: xml.Event) void {
        switch (event.data) {
            .start_element => |start| {
                self.elements += 1;
                self.name_bytes += start.name.raw.len;
                for (start.namespace_declarations) |declaration| {
                    const prefix = declaration.prefix orelse "";
                    self.namespace_declarations += 1;
                    self.namespace_uri_bytes += declaration.namespace_uri.len;
                    self.prefix_bytes += prefix.len;
                    self.marker(5);
                    self.bytes(prefix);
                    self.marker(6);
                    self.bytes(declaration.namespace_uri);
                }
                self.marker(1);
                self.name(start.name);
                for (start.attributes) |attribute| {
                    self.attributes += 1;
                    self.name_bytes += attribute.name.raw.len;
                    self.value_bytes += attribute.value.len;
                    self.marker(2);
                    self.name(attribute.name);
                    self.marker(3);
                    self.bytes(attribute.value);
                }
            },
            .end_element => |end| {
                self.name_bytes += end.name.raw.len;
                self.marker(4);
                self.name(end.name);
            },
            .text => |text| if (text.bytes.len > 0) {
                self.text_bytes += text.bytes.len;
                self.fragments += 1;
                self.bytes(text.bytes);
            },
            else => {},
        }
    }
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-persistent: {s}\n", .{@errorName(err)});
        return statusForError(err);
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args) orelse {
        std.debug.print(
            "usage: z-xml-persistent [--input=resident|stream] " ++
                "[--consumer=minimal|full] [--iterations=N] " ++
                "[--next-file=FILE --next-iterations=N] " ++
                "[--chunk-bytes=N] [--parser-storage=dynamic|fixed] " ++
                "[--report-memory] [--report-timing] [--release-memory] FILE\n",
            .{},
        );
        return 64;
    };

    const source_setup_start = if (options.report_timing)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    const file = try std.Io.Dir.cwd().openFile(init.io, options.path, .{});
    defer file.close(init.io);
    const file_size = (try file.stat(init.io)).size;
    const next_file: ?std.Io.File = if (options.next_path) |path|
        try std.Io.Dir.cwd().openFile(init.io, path, .{})
    else
        null;
    defer if (next_file) |opened| opened.close(init.io);
    const next_file_size = if (next_file) |opened| (try opened.stat(init.io)).size else 0;

    const input = switch (options.input) {
        .resident => resident: {
            const input_len = std.math.cast(usize, file_size) orelse
                return error.InputTooLarge;
            const bytes = try init.gpa.alloc(u8, input_len);
            errdefer init.gpa.free(bytes);
            if (try file.readPositionalAll(init.io, bytes, 0) != bytes.len) {
                return error.IncompleteRead;
            }
            break :resident bytes;
        },
        .stream => try init.gpa.alloc(u8, options.chunk_bytes),
    };
    defer init.gpa.free(input);
    const next_input: ?[]u8 = if (next_file) |opened|
        switch (options.input) {
            .resident => resident: {
                const input_len = std.math.cast(usize, next_file_size) orelse
                    return error.InputTooLarge;
                const bytes = try init.gpa.alloc(u8, input_len);
                errdefer init.gpa.free(bytes);
                if (try opened.readPositionalAll(init.io, bytes, 0) != bytes.len) {
                    return error.IncompleteRead;
                }
                break :resident bytes;
            },
            .stream => null,
        }
    else
        null;
    defer if (next_input) |bytes| init.gpa.free(bytes);

    var fixed_storage: [4096]u8 = undefined;
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&fixed_storage);
    var tracking: TrackingAllocator = .{ .child = switch (options.parser_storage) {
        .dynamic => init.gpa,
        .fixed => fixed_allocator.allocator(),
    } };
    const reader_options: xml.ReaderOptions = if (persistent_options.default_options)
        .{}
    else
        .{
            .namespaces = if (persistent_options.namespaces) .process else .raw,
            .dtd = .reject,
        };
    var file_reader = file.reader(init.io, input);
    var next_file_reader = if (next_file) |opened|
        opened.reader(init.io, next_input orelse input)
    else
        null;
    const source: xml.Source = switch (options.input) {
        .resident => .{ .slice = input },
        .stream => .{ .stream = &file_reader.interface },
    };
    const next_source: ?xml.Source = if (options.next_path != null)
        switch (options.input) {
            .resident => .{ .slice = next_input.? },
            .stream => .{ .stream = &next_file_reader.?.interface },
        }
    else
        null;
    const source_setup_ns = if (options.report_timing)
        source_setup_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds
    else
        0;
    const reader_init_start = if (options.report_timing)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    var reader = try xml.Reader.init(tracking.allocator(), source, reader_options);
    const reader_init_ns = if (options.report_timing)
        reader_init_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds
    else
        0;
    var reader_live = true;
    defer if (reader_live) reader.deinit();
    var reference: ?Stats = null;
    var next_reference: ?Stats = null;
    const first_document_start = if (options.report_timing)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    try drainAndCompare(&reader, options.consumer, &reference);
    const first_document_ns = if (options.report_timing)
        first_document_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds
    else
        0;
    const first_allocator_operations = tracking.operations();

    const primary_warm_start = if (options.report_timing and options.iterations > 1)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    for (1..options.iterations) |_| {
        if (options.input == .stream) try file_reader.seekTo(0);
        try reader.reset(source, reader_options, .retain_capacity);
        try drainAndCompare(&reader, options.consumer, &reference);
    }
    const primary_warm_ns = if (options.report_timing and options.iterations > 1)
        primary_warm_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds
    else
        0;
    const after_primary_operations = tracking.operations();

    const next_documents_start = if (options.report_timing and next_source != null)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    if (next_source) |replacement| {
        for (0..options.next_iterations) |iteration| {
            if (iteration > 0 and options.input == .stream) {
                try next_file_reader.?.seekTo(0);
            }
            try reader.reset(replacement, reader_options, .retain_capacity);
            try drainAndCompare(&reader, options.consumer, &next_reference);
        }
    }
    const next_documents_ns = if (options.report_timing and next_source != null)
        next_documents_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds
    else
        0;
    const after_next_operations = tracking.operations();

    const usage = reader.memoryUsage();
    const live_bytes_before_release = tracking.live_bytes;
    const release_start = if (options.report_timing and options.release_memory)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    if (options.release_memory) {
        try reader.reset(next_source orelse source, reader_options, .release_memory);
    }
    const release_ns = if (options.report_timing and options.release_memory)
        release_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds
    else
        0;
    const released_usage = reader.memoryUsage();
    const live_bytes_after_release = tracking.live_bytes;
    const after_release_operations = tracking.operations();
    const live_bytes_before_deinit = tracking.live_bytes;
    reader.deinit();
    reader_live = false;
    const memory_stats: MemoryStats = .{
        .input_bytes = file_size,
        .next_input_bytes = next_file_size,
        .caller_input_storage_bytes = input.len + if (next_input) |bytes| bytes.len else 0,
        .first_allocator_operations = first_allocator_operations,
        .primary_warm_allocator_operations = after_primary_operations -
            first_allocator_operations,
        .next_allocator_operations = after_next_operations - after_primary_operations,
        .warm_allocator_operations = after_next_operations - first_allocator_operations,
        .release_allocator_operations = after_release_operations - after_next_operations,
        .allocator_allocs = tracking.allocs,
        .allocator_resizes = tracking.resizes,
        .allocator_remaps = tracking.remaps,
        .requested_bytes = tracking.requested_bytes,
        .peak_live_bytes = tracking.peak_live_bytes,
        .retained_capacity = usage.retained_capacity,
        .live_bytes_before_release = live_bytes_before_release,
        .retained_capacity_after_release = released_usage.retained_capacity,
        .live_bytes_after_release = live_bytes_after_release,
        .live_bytes_before_deinit = live_bytes_before_deinit,
        .live_bytes_after_deinit = tracking.live_bytes,
    };
    const timing_stats: TimingStats = .{
        .source_setup_ns = source_setup_ns,
        .reader_init_ns = reader_init_ns,
        .first_document_ns = first_document_ns,
        .primary_warm_ns = primary_warm_ns,
        .next_documents_ns = next_documents_ns,
        .release_ns = release_ns,
    };
    try printStats(init.io, options, reference.?, next_reference, memory_stats, timing_stats);
    return 0;
}

fn drainAndCompare(
    reader: *xml.Reader,
    consumer: Consumer,
    reference: *?Stats,
) !void {
    var stats: Stats = .{ .consumer = consumer };
    try drain(reader, &stats);
    if (reference.*) |expected| {
        if (!std.meta.eql(expected, stats)) return error.IterationMismatch;
    } else {
        reference.* = stats;
    }
}

fn parseOptions(args: []const []const u8) ?Options {
    var options: Options = .{ .path = "" };
    for (args[1..]) |argument| {
        if (std.mem.startsWith(u8, argument, "--input=")) {
            const value = argument["--input=".len..];
            options.input = if (std.mem.eql(u8, value, "resident"))
                .resident
            else if (std.mem.eql(u8, value, "stream"))
                .stream
            else
                return null;
        } else if (std.mem.startsWith(u8, argument, "--consumer=")) {
            const value = argument["--consumer=".len..];
            options.consumer = if (std.mem.eql(u8, value, "minimal"))
                .minimal
            else if (std.mem.eql(u8, value, "full"))
                .full
            else
                return null;
        } else if (std.mem.startsWith(u8, argument, "--iterations=")) {
            options.iterations = std.fmt.parseInt(
                usize,
                argument["--iterations=".len..],
                10,
            ) catch return null;
            if (options.iterations == 0) return null;
        } else if (std.mem.startsWith(u8, argument, "--next-iterations=")) {
            options.next_iterations = std.fmt.parseInt(
                usize,
                argument["--next-iterations=".len..],
                10,
            ) catch return null;
            if (options.next_iterations == 0) return null;
        } else if (std.mem.startsWith(u8, argument, "--next-file=")) {
            const path = argument["--next-file=".len..];
            if (path.len == 0 or options.next_path != null) return null;
            options.next_path = path;
        } else if (std.mem.startsWith(u8, argument, "--chunk-bytes=")) {
            options.chunk_bytes = std.fmt.parseInt(
                usize,
                argument["--chunk-bytes=".len..],
                10,
            ) catch return null;
            if (options.chunk_bytes == 0) return null;
        } else if (std.mem.eql(u8, argument, "--report-memory")) {
            options.report_memory = true;
        } else if (std.mem.eql(u8, argument, "--report-timing")) {
            options.report_timing = true;
        } else if (std.mem.eql(u8, argument, "--release-memory")) {
            options.release_memory = true;
        } else if (std.mem.startsWith(u8, argument, "--parser-storage=")) {
            const value = argument["--parser-storage=".len..];
            options.parser_storage = if (std.mem.eql(u8, value, "dynamic"))
                .dynamic
            else if (std.mem.eql(u8, value, "fixed"))
                .fixed
            else
                return null;
        } else if (argument.len == 0 or argument[0] == '-' or options.path.len != 0) {
            return null;
        } else {
            options.path = argument;
        }
    }
    if ((options.next_path == null) != (options.next_iterations == 0)) return null;
    return if (options.path.len == 0) null else options;
}

fn drain(reader: *xml.Reader, stats: *Stats) !void {
    while (try reader.next()) |event| stats.observe(event);
}

fn printStats(
    io: std.Io,
    options: Options,
    stats: Stats,
    next_stats: ?Stats,
    memory: MemoryStats,
    timing: TimingStats,
) !void {
    var output_buffer: [4096]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(io, &output_buffer);
    const output = &output_file.interface;
    try output.print(
        "{{\"engine\":\"{s}\",\"input\":\"{s}\",\"consumer\":\"{s}\"," ++
            "\"iterations\":{d},\"chunk_bytes\":{d},\"elements\":{d}," ++
            "\"attributes\":{d},\"text_bytes\":{d},\"name_bytes\":{d}," ++
            "\"value_bytes\":{d},\"fragments\":{d}",
        .{
            ENGINE,
            @tagName(options.input),
            @tagName(options.consumer),
            options.iterations,
            options.chunk_bytes,
            stats.elements,
            stats.attributes,
            stats.text_bytes,
            stats.name_bytes,
            stats.value_bytes,
            stats.fragments,
        },
    );
    if (comptime persistent_options.namespace_summary) {
        try output.print(
            ",\"namespace_declarations\":{d},\"namespace_uri_bytes\":{d}," ++
                "\"local_name_bytes\":{d},\"prefix_bytes\":{d}",
            .{
                stats.namespace_declarations,
                stats.namespace_uri_bytes,
                stats.local_name_bytes,
                stats.prefix_bytes,
            },
        );
    }
    try output.writeAll(",\"accumulator\":");
    if (options.consumer == .full) {
        try output.print("\"{x:0>16}\"", .{stats.accumulator});
    } else {
        try output.writeAll("null");
    }
    if (next_stats) |next| {
        try output.print(
            ",\"next_iterations\":{d},\"next_input_bytes\":{d}," ++
                "\"next_elements\":{d},\"next_attributes\":{d}," ++
                "\"next_text_bytes\":{d},\"next_name_bytes\":{d}," ++
                "\"next_value_bytes\":{d},\"next_fragments\":{d}",
            .{
                options.next_iterations,
                memory.next_input_bytes,
                next.elements,
                next.attributes,
                next.text_bytes,
                next.name_bytes,
                next.value_bytes,
                next.fragments,
            },
        );
        if (comptime persistent_options.namespace_summary) {
            try output.print(
                ",\"next_namespace_declarations\":{d}," ++
                    "\"next_namespace_uri_bytes\":{d},\"next_local_name_bytes\":{d}," ++
                    "\"next_prefix_bytes\":{d}",
                .{
                    next.namespace_declarations,
                    next.namespace_uri_bytes,
                    next.local_name_bytes,
                    next.prefix_bytes,
                },
            );
        }
        try output.writeAll(",\"next_accumulator\":");
        if (options.consumer == .full) {
            try output.print("\"{x:0>16}\"", .{next.accumulator});
        } else {
            try output.writeAll("null");
        }
    }
    if (options.report_memory) {
        try output.print(
            ",\"input_bytes\":{d},\"caller_input_storage_bytes\":{d}," ++
                "\"parser_storage\":\"{s}\"," ++
                "\"first_allocator_operations\":{d}," ++
                "\"warm_allocator_operations\":{d},\"allocator_allocs\":{d}," ++
                "\"allocator_resizes\":{d},\"allocator_remaps\":{d}," ++
                "\"requested_bytes\":{d},\"peak_live_bytes\":{d}," ++
                "\"retained_capacity\":{d},\"live_bytes_before_deinit\":{d}," ++
                "\"live_bytes_after_deinit\":{d}",
            .{
                memory.input_bytes,
                memory.caller_input_storage_bytes,
                @tagName(options.parser_storage),
                memory.first_allocator_operations,
                memory.warm_allocator_operations,
                memory.allocator_allocs,
                memory.allocator_resizes,
                memory.allocator_remaps,
                memory.requested_bytes,
                memory.peak_live_bytes,
                memory.retained_capacity,
                memory.live_bytes_before_deinit,
                memory.live_bytes_after_deinit,
            },
        );
        if (next_stats != null) {
            try output.print(
                ",\"primary_warm_allocator_operations\":{d}," ++
                    "\"next_allocator_operations\":{d}",
                .{
                    memory.primary_warm_allocator_operations,
                    memory.next_allocator_operations,
                },
            );
        }
        if (options.release_memory) {
            try output.print(
                ",\"release_allocator_operations\":{d}," ++
                    "\"live_bytes_before_release\":{d}," ++
                    "\"retained_capacity_after_release\":{d}," ++
                    "\"live_bytes_after_release\":{d}",
                .{
                    memory.release_allocator_operations,
                    memory.live_bytes_before_release,
                    memory.retained_capacity_after_release,
                    memory.live_bytes_after_release,
                },
            );
        }
    }
    if (options.report_timing) {
        try output.print(
            ",\"source_setup_ns\":{d},\"reader_init_ns\":{d}," ++
                "\"first_document_ns\":{d},\"primary_warm_ns\":{d}," ++
                "\"next_documents_ns\":{d},\"release_ns\":{d}",
            .{
                timing.source_setup_ns,
                timing.reader_init_ns,
                timing.first_document_ns,
                timing.primary_warm_ns,
                timing.next_documents_ns,
                timing.release_ns,
            },
        );
    }
    try output.writeAll("}\n");
    try output.flush();
}

fn statusForError(err: anyerror) u8 {
    return switch (err) {
        error.InvalidXml,
        error.InvalidDtd,
        error.NotValid,
        error.InvalidEncoding,
        error.UnsupportedEncoding,
        error.UnsupportedVersion,
        error.DtdForbidden,
        => 2,
        error.LimitExceeded, error.OutOfMemory, error.InputTooLarge => 3,
        else => 1,
    };
}

// --- Tests ---

test "[unit] - [persistent adapter options]: parses the shared controls exactly" {
    const args = [_][]const u8{
        "z-xml-persistent",
        "--input=stream",
        "--consumer=minimal",
        "--iterations=3",
        "--chunk-bytes=7",
        "--parser-storage=fixed",
        "--report-memory",
        "input.xml",
    };
    const options = parseOptions(&args).?;
    try std.testing.expectEqual(InputModel.stream, options.input);
    try std.testing.expectEqual(Consumer.minimal, options.consumer);
    try std.testing.expectEqual(@as(usize, 3), options.iterations);
    try std.testing.expectEqual(@as(usize, 7), options.chunk_bytes);
    try std.testing.expectEqual(ParserStorage.fixed, options.parser_storage);
    try std.testing.expect(options.report_memory);
    try std.testing.expectEqualStrings("input.xml", options.path);
    try std.testing.expect(parseOptions(&.{ "z-xml-persistent", "--iterations=0", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-persistent", "--chunk-bytes=0", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-persistent", "--parser-storage=other", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-persistent", "x", "y" }) == null);
}

test "[unit] - [persistent adapter options]: second-file schedules require both controls" {
    const args = [_][]const u8{
        "z-xml-persistent",
        "--next-file=small.xml",
        "--next-iterations=4096",
        "--report-timing",
        "--release-memory",
        "large.xml",
    };
    const options = parseOptions(&args).?;
    try std.testing.expectEqualStrings("small.xml", options.next_path.?);
    try std.testing.expectEqual(@as(usize, 4096), options.next_iterations);
    try std.testing.expect(options.report_timing);
    try std.testing.expect(options.release_memory);
    try std.testing.expect(
        parseOptions(&.{ "z-xml-persistent", "--next-file=x", "y" }) == null,
    );
    try std.testing.expect(
        parseOptions(&.{ "z-xml-persistent", "--next-iterations=1", "y" }) == null,
    );
}

test "[unit] - [tracking allocator]: tracks owned bytes and cleanup" {
    var tracking: TrackingAllocator = .{ .child = std.testing.allocator };
    const allocator = tracking.allocator();
    const first = try allocator.alloc(u8, 4);
    const second = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(@as(u64, 2), tracking.allocs);
    try std.testing.expectEqual(@as(u64, 2), tracking.operations());
    try std.testing.expectEqual(@as(u64, 12), tracking.requested_bytes);
    try std.testing.expectEqual(@as(usize, 12), tracking.live_bytes);
    try std.testing.expectEqual(@as(usize, 12), tracking.peak_live_bytes);
    allocator.free(first);
    allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), tracking.live_bytes);
}

test "[unit] - [persistent adapter status]: preserves parser and resource categories" {
    try std.testing.expectEqual(@as(u8, 2), statusForError(error.InvalidXml));
    try std.testing.expectEqual(@as(u8, 3), statusForError(error.LimitExceeded));
    try std.testing.expectEqual(@as(u8, 3), statusForError(error.OutOfMemory));
    try std.testing.expectEqual(@as(u8, 1), statusForError(error.ReadFailed));
}
