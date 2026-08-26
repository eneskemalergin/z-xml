//! Persistent adapter for normal Reader profiles.

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
    chunk_bytes: usize = DEFAULT_CHUNK_BYTES,
    report_memory: bool = false,
    parser_storage: ParserStorage = .dynamic,
    path: []const u8,
};

const MemoryStats = struct {
    input_bytes: u64,
    first_allocator_operations: u64,
    warm_allocator_operations: u64,
    allocator_allocs: u64,
    allocator_resizes: u64,
    allocator_remaps: u64,
    requested_bytes: u64,
    peak_live_bytes: usize,
    retained_capacity: usize,
    live_bytes_before_deinit: usize,
    live_bytes_after_deinit: usize,
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
                "[--chunk-bytes=N] [--parser-storage=dynamic|fixed] " ++
                "[--report-memory] FILE\n",
            .{},
        );
        return 64;
    };

    const file = try std.Io.Dir.cwd().openFile(init.io, options.path, .{});
    defer file.close(init.io);
    const file_size = (try file.stat(init.io)).size;

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
    const source: xml.Source = switch (options.input) {
        .resident => .{ .slice = input },
        .stream => .{ .stream = &file_reader.interface },
    };
    var reader = try xml.Reader.init(tracking.allocator(), source, reader_options);
    var reader_live = true;
    defer if (reader_live) reader.deinit();
    var reference: ?Stats = null;
    var first_allocator_operations: u64 = 0;
    for (0..options.iterations) |iteration| {
        if (iteration > 0) {
            if (options.input == .stream) try file_reader.seekTo(0);
            try reader.reset(source, reader_options, .retain_capacity);
        }
        var stats: Stats = .{ .consumer = options.consumer };
        try drain(&reader, &stats);
        if (reference) |expected| {
            if (!std.meta.eql(expected, stats)) return error.IterationMismatch;
        } else {
            reference = stats;
        }
        if (iteration == 0) {
            first_allocator_operations = allocatorOperations(tracking);
        }
    }

    const usage = reader.memoryUsage();
    const live_bytes_before_deinit = tracking.live_bytes;
    reader.deinit();
    reader_live = false;
    const memory_stats: MemoryStats = .{
        .input_bytes = file_size,
        .first_allocator_operations = first_allocator_operations,
        .warm_allocator_operations = allocatorOperations(tracking) - first_allocator_operations,
        .allocator_allocs = tracking.allocs,
        .allocator_resizes = tracking.resizes,
        .allocator_remaps = tracking.remaps,
        .requested_bytes = tracking.requested_bytes,
        .peak_live_bytes = tracking.peak_live_bytes,
        .retained_capacity = usage.retained_capacity,
        .live_bytes_before_deinit = live_bytes_before_deinit,
        .live_bytes_after_deinit = tracking.live_bytes,
    };
    try printStats(init.io, options, reference.?, memory_stats);
    return 0;
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
        } else if (std.mem.startsWith(u8, argument, "--chunk-bytes=")) {
            options.chunk_bytes = std.fmt.parseInt(
                usize,
                argument["--chunk-bytes=".len..],
                10,
            ) catch return null;
            if (options.chunk_bytes == 0) return null;
        } else if (std.mem.eql(u8, argument, "--report-memory")) {
            options.report_memory = true;
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
    return if (options.path.len == 0) null else options;
}

fn drain(reader: *xml.Reader, stats: *Stats) !void {
    while (try reader.next()) |event| stats.observe(event);
}

fn allocatorOperations(tracking: TrackingAllocator) u64 {
    return tracking.allocs + tracking.resizes + tracking.remaps;
}

fn printStats(
    io: std.Io,
    options: Options,
    stats: Stats,
    memory: MemoryStats,
) !void {
    var output_buffer: [1024]u8 = undefined;
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
    if (options.report_memory) {
        try output.print(
            ",\"input_bytes\":{d},\"parser_storage\":\"{s}\"," ++
                "\"first_allocator_operations\":{d}," ++
                "\"warm_allocator_operations\":{d},\"allocator_allocs\":{d}," ++
                "\"allocator_resizes\":{d},\"allocator_remaps\":{d}," ++
                "\"requested_bytes\":{d},\"peak_live_bytes\":{d}," ++
                "\"retained_capacity\":{d},\"live_bytes_before_deinit\":{d}," ++
                "\"live_bytes_after_deinit\":{d}",
            .{
                memory.input_bytes,
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

test "[unit] - [tracking allocator]: tracks owned bytes and cleanup" {
    var tracking: TrackingAllocator = .{ .child = std.testing.allocator };
    const allocator = tracking.allocator();
    const first = try allocator.alloc(u8, 4);
    const second = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(@as(u64, 2), tracking.allocs);
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
