//! Runs manifest-selected public Writer workloads for correctness and measurement.
//!
//! One executable owns attributes, text, namespace, sink, and repeated-construction shapes. The
//! shape matrix selects the work, value, and sink model. Writer allocations use a tracking
//! allocator, while input, sink buffering, and optional output capture remain caller-owned and are
//! reported separately. Verification retains output only long enough to check exact or Reader
//! semantics; normal measurement discards output after the sink accepts it.

const std = @import("std");
const xml = @import("z_xml");
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const MANIFEST_SCHEMA = "z-xml-shape-matrix-v1";
const RESULT_SCHEMA = "z-xml-writer-result-v1";
const MAX_MANIFEST_BYTES = 256 * 1024;
const MAX_TEXT_BYTES = 64 * 1024 * 1024;
const MAX_ATTRIBUTES = 256;
const MAX_NAMESPACE_DEPTH = 256;
const MAX_DOCUMENTS = 4096;
const MAX_CAPTURE_BYTES = 128 * 1024 * 1024;
const BUFFERED_SINK_BYTES = 64 * 1024;
const SHORT_WRITE_BYTES = 7;
const TEXT_FRAGMENT_BYTES = 4096;
const DECLARATION = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
const ATTRIBUTE_VALUE = "v<&\"\t";
const ESCAPED_TEXT_PATTERN = "a<&\r";

const Shape = enum {
    attributes,
    unchanged_text,
    escaped_text,
    fragmented_text,
    namespace_depth,
    short_sink,
    repeated_documents,

    fn id(self: Shape) []const u8 {
        return switch (self) {
            .attributes => "writer-attributes",
            .unchanged_text => "writer-unchanged-text",
            .escaped_text => "writer-escaped-text",
            .fragmented_text => "writer-fragmented-text",
            .namespace_depth => "writer-namespace-depth",
            .short_sink => "writer-short-sink",
            .repeated_documents => "writer-repeated-documents",
        };
    }

    fn fromId(shape_id: []const u8) ?Shape {
        inline for (std.meta.tags(Shape)) |shape| {
            if (std.mem.eql(u8, shape_id, shape.id())) return shape;
        }
        return null;
    }
};

const SinkModel = enum {
    buffered,
    unbuffered,
    one_byte,
    short,

    fn manifestName(self: SinkModel) []const u8 {
        return switch (self) {
            .buffered => "buffered-sink",
            .unbuffered => "unbuffered-sink",
            .one_byte => "one-byte-sink",
            .short => "short-sink",
        };
    }

    fn fromManifestName(name: []const u8) ?SinkModel {
        inline for (std.meta.tags(SinkModel)) |model| {
            if (std.mem.eql(u8, name, model.manifestName())) return model;
        }
        return null;
    }

    fn maxWriteBytes(self: SinkModel) ?usize {
        return switch (self) {
            .one_byte => 1,
            .short => SHORT_WRITE_BYTES,
            else => null,
        };
    }
};

const Selection = struct {
    shape: Shape,
    value: []const u8,
    amount: usize,
    sink: SinkModel,
};

const Options = struct {
    manifest: []const u8,
    shape_id: []const u8,
    value: []const u8,
    sink_name: []const u8,
    verify: bool,
};

const Result = struct {
    documents: usize = 0,
    elements: usize = 0,
    attributes: usize = 0,
    namespace_declarations: usize = 0,
    text_input_bytes: usize = 0,
    text_fragments: usize = 0,
    output_bytes: u64 = 0,
    sink_accepted_bytes: u64 = 0,
    sink_calls: u64 = 0,
    sink_flushes: u64 = 0,
    writer_peak_open_elements: usize = 0,
    writer_peak_namespace_bindings: usize = 0,
    writer_peak_pending_start_tag_bytes: usize = 0,
    writer_peak_retained_capacity_bytes: usize = 0,
    writer_final_retained_capacity_bytes: usize = 0,
    writer_allocator_allocs: u64 = 0,
    writer_allocator_resizes: u64 = 0,
    writer_allocator_remaps: u64 = 0,
    writer_requested_bytes: u64 = 0,
    writer_peak_live_bytes: usize = 0,
    writer_live_bytes_before_deinit: usize = 0,
    writer_live_bytes_after_deinit: usize = 0,
    caller_input_bytes: usize = 0,
    caller_sink_storage_bytes: usize = 0,
    caller_oracle_storage_bytes: usize = 0,
};

const Execution = struct {
    allocator: std.mem.Allocator,
    capture: []u8,
    result: Result,

    fn deinit(self: *Execution) void {
        if (self.capture.len != 0) self.allocator.free(self.capture);
        self.* = undefined;
    }
};

const CountingSink = struct {
    interface: std.Io.Writer,
    capture: []u8,
    capture_len: usize = 0,
    accepted_bytes: u64 = 0,
    drain_calls: u64 = 0,
    flush_calls: u64 = 0,
    max_write_bytes: ?usize,

    fn init(buffer: []u8, capture: []u8, max_write_bytes: ?usize) CountingSink {
        return .{
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
                .buffer = buffer,
            },
            .capture = capture,
            .max_write_bytes = max_write_bytes,
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        std.debug.assert(data.len != 0);
        const self: *CountingSink = @alignCast(@fieldParentPtr("interface", writer));
        self.drain_calls += 1;
        var remaining = self.max_write_bytes orelse std.math.maxInt(usize);

        const buffered = @min(writer.end, remaining);
        try self.accept(writer.buffer[0..buffered]);
        remaining -= buffered;
        if (buffered != writer.end) {
            std.mem.copyForwards(u8, writer.buffer[0 .. writer.end - buffered], writer.buffer[buffered..writer.end]);
            writer.end -= buffered;
            return 0;
        }
        writer.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            const count = @min(bytes.len, remaining);
            try self.accept(bytes[0..count]);
            consumed += count;
            remaining -= count;
            if (count != bytes.len or remaining == 0) return consumed;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            const count = @min(pattern.len, remaining);
            try self.accept(pattern[0..count]);
            consumed += count;
            remaining -= count;
            if (count != pattern.len or remaining == 0) return consumed;
        }
        return consumed;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *CountingSink = @alignCast(@fieldParentPtr("interface", writer));
        self.flush_calls += 1;
        while (writer.end != 0) _ = try drain(writer, &.{""}, 1);
    }

    fn accept(self: *CountingSink, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const new_accepted = std.math.add(u64, self.accepted_bytes, bytes.len) catch
            return error.WriteFailed;
        if (self.capture.len != 0) {
            const new_len = std.math.add(usize, self.capture_len, bytes.len) catch
                return error.WriteFailed;
            if (new_len > self.capture.len) return error.WriteFailed;
            @memcpy(self.capture[self.capture_len..new_len], bytes);
            self.capture_len = new_len;
        }
        self.accepted_bytes = new_accepted;
    }
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-writer: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args) orelse {
        std.debug.print(
            "usage: z-xml-writer [--verify] MANIFEST SHAPE VALUE SINK\n",
            .{},
        );
        return 64;
    };
    const manifest = try readManifest(init.gpa, init.io, options.manifest);
    defer init.gpa.free(manifest);
    const sink_model = SinkModel.fromManifestName(options.sink_name) orelse
        return error.InvalidSelection;
    const selection = try selectManifest(
        manifest,
        options.shape_id,
        options.value,
        sink_model,
    );
    var execution = try execute(init.gpa, selection, options.verify);
    defer execution.deinit();
    try printResult(init.io, selection, options.verify, execution.result);
    return 0;
}

fn parseOptions(args: []const []const u8) ?Options {
    var positional: [4][]const u8 = undefined;
    var positional_count: usize = 0;
    var verify = false;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--verify")) {
            if (verify) return null;
            verify = true;
        } else if (argument.len == 0 or argument[0] == '-' or positional_count == positional.len) {
            return null;
        } else {
            positional[positional_count] = argument;
            positional_count += 1;
        }
    }
    if (positional_count != positional.len) return null;
    return .{
        .manifest = positional[0],
        .shape_id = positional[1],
        .value = positional[2],
        .sink_name = positional[3],
        .verify = verify,
    };
}

fn readManifest(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = std.math.cast(usize, (try file.stat(io)).size) orelse
        return error.InvalidManifest;
    if (size == 0 or size > MAX_MANIFEST_BYTES) return error.InvalidManifest;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != size) return error.IncompleteRead;
    return bytes;
}

fn selectManifest(
    manifest: []const u8,
    shape_id: []const u8,
    value: []const u8,
    sink: SinkModel,
) !Selection {
    const shape = Shape.fromId(shape_id) orelse return error.InvalidSelection;
    var schema_count: usize = 0;
    var header_seen = false;
    var selected: ?Selection = null;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (std.mem.eql(u8, std.mem.trim(u8, line[1..], " \t"), MANIFEST_SCHEMA)) {
                schema_count += 1;
            }
            continue;
        }
        var fields: [12][]const u8 = undefined;
        if (!splitFields(line, &fields)) return error.InvalidManifest;
        if (!header_seen) {
            if (!std.mem.eql(u8, line, "id\tfamily\tlane\tprofile\tinput_models\tseed_fixture\tgenerator\tsize_plan\texpected\toracle\tstatus\tnotes")) {
                return error.InvalidManifest;
            }
            header_seen = true;
            continue;
        }
        if (!std.mem.eql(u8, fields[0], shape_id)) continue;
        if (selected != null) return error.InvalidManifest;
        if (!std.mem.eql(u8, fields[2], "writer") or
            !std.mem.eql(u8, fields[3], "writer-xml10-namespaces") or
            !std.mem.eql(u8, fields[6], shape.id()) or
            !std.mem.eql(u8, fields[8], "emit") or
            !std.mem.eql(u8, fields[10], "ready") or
            !expectedOracle(shape, fields[9]))
        {
            return error.InvalidManifest;
        }
        if (!listContains(fields[4], sink.manifestName()) or
            !planContains(shape, fields[7], value)) return error.InvalidSelection;
        selected = .{
            .shape = shape,
            .value = value,
            .amount = try parseAmount(shape, value),
            .sink = sink,
        };
    }
    if (schema_count != 1 or !header_seen) return error.InvalidManifest;
    return selected orelse error.InvalidSelection;
}

fn splitFields(line: []const u8, fields: *[12][]const u8) bool {
    var iterator = std.mem.splitScalar(u8, line, '\t');
    var count: usize = 0;
    while (iterator.next()) |field| {
        if (count == fields.len) return false;
        fields[count] = field;
        count += 1;
    }
    return count == fields.len;
}

fn expectedOracle(shape: Shape, oracle: []const u8) bool {
    const expected = if (shape == .namespace_depth)
        "writer-namespace-output-v1"
    else
        "writer-output-v1";
    return std.mem.eql(u8, oracle, expected);
}

fn listContains(list: []const u8, expected: []const u8) bool {
    var values = std.mem.splitScalar(u8, list, ',');
    while (values.next()) |item| {
        if (std.mem.eql(u8, item, expected)) return true;
    }
    return false;
}

fn planContains(shape: Shape, plan: []const u8, value: []const u8) bool {
    const values = switch (shape) {
        .attributes => std.mem.cutPrefix(u8, plan, "attributes:") orelse return false,
        .namespace_depth => std.mem.cutPrefix(u8, plan, "depth:") orelse return false,
        .repeated_documents => std.mem.cutPrefix(u8, plan, "documents:") orelse return false,
        else => plan,
    };
    return listContains(values, value);
}

fn parseAmount(shape: Shape, value: []const u8) !usize {
    const amount = switch (shape) {
        .attributes, .namespace_depth, .repeated_documents => std.fmt.parseInt(usize, value, 10) catch return error.InvalidSelection,
        else => try parseBinarySize(value),
    };
    const maximum: usize = switch (shape) {
        .attributes => MAX_ATTRIBUTES,
        .namespace_depth => MAX_NAMESPACE_DEPTH,
        .repeated_documents => MAX_DOCUMENTS,
        else => MAX_TEXT_BYTES,
    };
    if (amount == 0 or amount > maximum) return error.InvalidSelection;
    return amount;
}

fn parseBinarySize(value: []const u8) !usize {
    if (value.len < 2) return error.InvalidSelection;
    const multiplier: usize = switch (value[value.len - 1]) {
        'k' => 1024,
        'm' => 1024 * 1024,
        else => return error.InvalidSelection,
    };
    const count = std.fmt.parseInt(usize, value[0 .. value.len - 1], 10) catch
        return error.InvalidSelection;
    return std.math.mul(usize, count, multiplier) catch error.InvalidSelection;
}

fn execute(allocator: std.mem.Allocator, selection: Selection, verify: bool) !Execution {
    const input_len = switch (selection.shape) {
        .unchanged_text, .escaped_text, .short_sink => selection.amount,
        .fragmented_text => @min(selection.amount, TEXT_FRAGMENT_BYTES),
        else => 0,
    };
    var empty_input: [0]u8 = .{};
    const input: []u8 = if (input_len == 0) &empty_input else try allocator.alloc(u8, input_len);
    defer if (input.len != 0) allocator.free(input);
    fillInput(selection.shape, input);

    const capture_len = if (verify) try captureUpperBound(selection) else 0;
    const capture: []u8 = if (capture_len == 0)
        @constCast(&.{})
    else
        try allocator.alloc(u8, capture_len);
    errdefer if (capture.len != 0) allocator.free(capture);

    var empty_sink_buffer: [0]u8 = .{};
    const sink_buffer: []u8 = if (selection.sink == .buffered)
        try allocator.alloc(u8, BUFFERED_SINK_BYTES)
    else
        &empty_sink_buffer;
    defer if (sink_buffer.len != 0) allocator.free(sink_buffer);
    var sink = CountingSink.init(sink_buffer, capture, selection.sink.maxWriteBytes());
    var tracking: TrackingAllocator = .{ .child = allocator };
    var result: Result = .{
        .caller_input_bytes = input.len,
        .caller_sink_storage_bytes = sink_buffer.len,
        .caller_oracle_storage_bytes = capture.len,
    };

    const document_count = if (selection.shape == .repeated_documents)
        selection.amount
    else
        1;
    for (0..document_count) |_| {
        try writeDocument(&sink, &tracking, selection, input, &result);
    }
    result.sink_accepted_bytes = sink.accepted_bytes;
    result.sink_calls = sink.drain_calls;
    result.sink_flushes = sink.flush_calls;
    result.writer_allocator_allocs = tracking.allocs;
    result.writer_allocator_resizes = tracking.resizes;
    result.writer_allocator_remaps = tracking.remaps;
    result.writer_requested_bytes = tracking.requested_bytes;
    result.writer_peak_live_bytes = tracking.peak_live_bytes;
    result.writer_live_bytes_after_deinit = tracking.live_bytes;
    try validateResult(result);
    if (verify) try verifyOutput(allocator, selection, input, capture[0..sink.capture_len]);
    return .{
        .allocator = allocator,
        .capture = capture,
        .result = result,
    };
}

fn validateResult(result: Result) !void {
    if (result.output_bytes != result.sink_accepted_bytes or
        result.writer_live_bytes_after_deinit != 0)
    {
        return error.InvalidSinkResult;
    }
}

fn fillInput(shape: Shape, input: []u8) void {
    switch (shape) {
        .escaped_text => for (input, 0..) |*byte, index| {
            byte.* = ESCAPED_TEXT_PATTERN[index % ESCAPED_TEXT_PATTERN.len];
        },
        else => @memset(input, 'x'),
    }
}

fn captureUpperBound(selection: Selection) !usize {
    const syntax: usize = 128;
    const estimate = switch (selection.shape) {
        .attributes => try std.math.mul(usize, selection.amount, 64),
        .unchanged_text, .fragmented_text, .short_sink => selection.amount,
        .escaped_text => try std.math.mul(usize, selection.amount, 6),
        .namespace_depth => try std.math.mul(usize, selection.amount, 96),
        .repeated_documents => try std.math.mul(usize, selection.amount, 64),
    };
    const total = std.math.add(usize, estimate, syntax) catch
        return error.InvalidSelection;
    if (total > MAX_CAPTURE_BYTES) return error.InvalidSelection;
    return total;
}

fn writeDocument(
    sink: *CountingSink,
    tracking: *TrackingAllocator,
    selection: Selection,
    input: []const u8,
    result: *Result,
) !void {
    const accepted_before = sink.accepted_bytes;
    var writer = try xml.Writer.init(tracking.allocator(), &sink.interface, .{});
    var writer_live = true;
    defer if (writer_live) writer.deinit();

    try writer.startDocument();
    sampleWriter(result, &writer);
    switch (selection.shape) {
        .attributes => try writeAttributes(&writer, selection.amount, result),
        .unchanged_text, .escaped_text, .short_sink => {
            try writer.startElement("root");
            sampleWriter(result, &writer);
            try writer.text(input);
            sampleWriter(result, &writer);
            try writer.endElement();
            result.elements += 1;
            result.text_input_bytes += input.len;
            result.text_fragments += 1;
        },
        .fragmented_text => try writeFragmentedText(
            &writer,
            selection.amount,
            input,
            result,
        ),
        .namespace_depth => try writeNamespaceDepth(&writer, selection.amount, result),
        .repeated_documents => {
            try writer.startElement("root");
            sampleWriter(result, &writer);
            try writer.endElement();
            result.elements += 1;
        },
    }
    try writer.endDocument();
    sampleWriter(result, &writer);
    const offset = writer.byteOffset() orelse return error.InvalidSinkResult;
    result.output_bytes = std.math.add(u64, result.output_bytes, offset) catch
        return error.InvalidSinkResult;
    result.writer_final_retained_capacity_bytes = writer.memoryUsage().retained_capacity_bytes;
    result.writer_live_bytes_before_deinit = @max(
        result.writer_live_bytes_before_deinit,
        tracking.live_bytes,
    );
    writer.deinit();
    writer_live = false;
    if (tracking.live_bytes != 0) return error.WriterLeak;
    sink.interface.flush() catch return error.SinkFailure;
    if (sink.accepted_bytes - accepted_before != offset) return error.InvalidSinkResult;
    result.documents += 1;
}

fn writeAttributes(writer: *xml.Writer, count: usize, result: *Result) !void {
    try writer.startElement("root");
    sampleWriter(result, writer);
    for (0..count) |index| {
        var name_buffer: [4]u8 = undefined;
        try writer.attribute(attributeName(index, &name_buffer), ATTRIBUTE_VALUE);
        sampleWriter(result, writer);
    }
    try writer.endElement();
    result.elements += 1;
    result.attributes += count;
}

fn writeFragmentedText(
    writer: *xml.Writer,
    total: usize,
    fragment: []const u8,
    result: *Result,
) !void {
    try writer.startElement("root");
    sampleWriter(result, writer);
    var remaining = total;
    while (remaining != 0) {
        const count = @min(remaining, fragment.len);
        try writer.text(fragment[0..count]);
        sampleWriter(result, writer);
        result.text_fragments += 1;
        remaining -= count;
    }
    try writer.endElement();
    result.elements += 1;
    result.text_input_bytes += total;
}

fn writeNamespaceDepth(writer: *xml.Writer, depth: usize, result: *Result) !void {
    for (0..depth) |index| {
        try writer.startElement("p:item");
        sampleWriter(result, writer);
        try writer.namespace("p", namespaceUri(index));
        sampleWriter(result, writer);
    }
    for (0..depth) |_| try writer.endElement();
    result.elements += depth;
    result.namespace_declarations += depth;
}

fn sampleWriter(result: *Result, writer: *const xml.Writer) void {
    const usage = writer.memoryUsage();
    result.writer_peak_open_elements = @max(
        result.writer_peak_open_elements,
        usage.open_element_count,
    );
    result.writer_peak_namespace_bindings = @max(
        result.writer_peak_namespace_bindings,
        usage.namespace_binding_count,
    );
    result.writer_peak_pending_start_tag_bytes = @max(
        result.writer_peak_pending_start_tag_bytes,
        usage.pending_start_tag_bytes,
    );
    result.writer_peak_retained_capacity_bytes = @max(
        result.writer_peak_retained_capacity_bytes,
        usage.retained_capacity_bytes,
    );
}

fn attributeName(index: usize, buffer: *[4]u8) []const u8 {
    std.debug.assert(index < 26 * 26 * 26);
    buffer.* = .{
        'a',
        @intCast('A' + index / (26 * 26)),
        @intCast('A' + index / 26 % 26),
        @intCast('A' + index % 26),
    };
    return buffer;
}

fn namespaceUri(index: usize) []const u8 {
    return if (index % 2 == 0) "urn:even" else "urn:odd";
}

fn verifyOutput(
    allocator: std.mem.Allocator,
    selection: Selection,
    input: []const u8,
    output: []const u8,
) !void {
    if (selection.shape == .repeated_documents) {
        const document = DECLARATION ++ "<root/>";
        const expected_len = std.math.mul(usize, selection.amount, document.len) catch
            return error.OracleMismatch;
        if (output.len != expected_len) return error.OracleMismatch;
        for (0..selection.amount) |index| {
            const start = index * document.len;
            if (!std.mem.eql(u8, output[start..][0..document.len], document)) {
                return error.OracleMismatch;
            }
        }
        return;
    }

    var reader = try xml.Reader.init(allocator, .{ .slice = output }, .{ .dtd = .reject });
    defer reader.deinit();
    var elements: usize = 0;
    var attributes: usize = 0;
    var declarations: usize = 0;
    var text_position: usize = 0;
    var document_starts: usize = 0;
    var document_ends: usize = 0;
    var end_elements: usize = 0;
    var active_depth: usize = 0;
    var max_depth: usize = 0;
    while (try reader.next()) |event| switch (event.data) {
        .document_start => {
            document_starts += 1;
        },
        .start_element => |start| {
            active_depth += 1;
            max_depth = @max(max_depth, active_depth);
            if (selection.shape == .attributes) {
                if (elements != 0 or !std.mem.eql(u8, start.name.raw, "root")) {
                    return error.OracleMismatch;
                }
                if (start.attributes.len != selection.amount) return error.OracleMismatch;
                for (start.attributes, 0..) |attribute, index| {
                    var name_buffer: [4]u8 = undefined;
                    if (!std.mem.eql(u8, attribute.name.raw, attributeName(index, &name_buffer)) or
                        !std.mem.eql(u8, attribute.value, ATTRIBUTE_VALUE))
                    {
                        return error.OracleMismatch;
                    }
                }
            } else if (selection.shape == .namespace_depth) {
                const expanded = start.name.expanded orelse return error.OracleMismatch;
                if (!std.mem.eql(u8, start.name.raw, "p:item") or
                    !std.mem.eql(u8, expanded.local, "item") or
                    expanded.prefix == null or
                    !std.mem.eql(u8, expanded.prefix.?, "p") or
                    expanded.namespace_uri == null or
                    !std.mem.eql(u8, expanded.namespace_uri.?, namespaceUri(elements)) or
                    start.namespace_declarations.len != 1)
                {
                    return error.OracleMismatch;
                }
                const declaration = start.namespace_declarations[0];
                if (declaration.prefix == null or
                    !std.mem.eql(u8, declaration.prefix.?, "p") or
                    !std.mem.eql(u8, declaration.namespace_uri, namespaceUri(elements)))
                {
                    return error.OracleMismatch;
                }
            } else if (elements != 0 or !std.mem.eql(u8, start.name.raw, "root")) {
                return error.OracleMismatch;
            }
            elements += 1;
            attributes += start.attributes.len;
            declarations += start.namespace_declarations.len;
        },
        .end_element => {
            if (active_depth == 0) return error.OracleMismatch;
            active_depth -= 1;
            end_elements += 1;
        },
        .text => |text| {
            for (text.bytes) |byte| {
                if (text_position >= selection.amount) return error.OracleMismatch;
                const expected = expectedTextByte(selection.shape, input, text_position) orelse
                    return error.OracleMismatch;
                if (byte != expected) return error.OracleMismatch;
                text_position += 1;
            }
        },
        .document_end => {
            if (active_depth != 0) return error.OracleMismatch;
            document_ends += 1;
        },
        .document_type,
        .comment,
        .processing_instruction,
        .skipped_external_source,
        => return error.OracleMismatch,
    };
    const expected_text = switch (selection.shape) {
        .unchanged_text, .escaped_text, .fragmented_text, .short_sink => selection.amount,
        else => 0,
    };
    const expected_depth = if (selection.shape == .namespace_depth)
        selection.amount
    else
        1;
    if (document_starts != 1 or
        document_ends != 1 or
        active_depth != 0 or
        elements != end_elements or
        max_depth != expected_depth or
        elements != expectedElements(selection) or
        attributes != expectedAttributes(selection) or
        declarations != expectedNamespaces(selection) or
        text_position != expected_text)
    {
        return error.OracleMismatch;
    }
}

fn expectedTextByte(shape: Shape, input: []const u8, position: usize) ?u8 {
    return switch (shape) {
        .fragmented_text => input[position % input.len],
        .unchanged_text, .escaped_text, .short_sink => input[position],
        else => null,
    };
}

fn expectedElements(selection: Selection) usize {
    return switch (selection.shape) {
        .namespace_depth => selection.amount,
        else => 1,
    };
}

fn expectedAttributes(selection: Selection) usize {
    return if (selection.shape == .attributes) selection.amount else 0;
}

fn expectedNamespaces(selection: Selection) usize {
    return if (selection.shape == .namespace_depth) selection.amount else 0;
}

fn printResult(io: std.Io, selection: Selection, verified: bool, result: Result) !void {
    var output_buffer: [4096]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(io, &output_buffer);
    const output = &output_file.interface;
    try output.print(
        "{{\"schema\":\"{s}\",\"target\":\"z-xml-writer\"," ++
            "\"shape\":\"{s}\",\"value\":\"{s}\",\"sink\":\"{s}\"," ++
            "\"verified\":{},\"documents\":{d},\"elements\":{d}," ++
            "\"attributes\":{d},\"namespace_declarations\":{d}," ++
            "\"text_input_bytes\":{d},\"text_fragments\":{d}," ++
            "\"output_bytes\":{d},\"sink_accepted_bytes\":{d}," ++
            "\"sink_calls\":{d},\"sink_flushes\":{d}," ++
            "\"writer_peak_open_elements\":{d}," ++
            "\"writer_peak_namespace_bindings\":{d}," ++
            "\"writer_peak_pending_start_tag_bytes\":{d}," ++
            "\"writer_peak_retained_capacity_bytes\":{d}," ++
            "\"writer_final_retained_capacity_bytes\":{d}," ++
            "\"writer_allocator_allocs\":{d},\"writer_allocator_resizes\":{d}," ++
            "\"writer_allocator_remaps\":{d},\"writer_requested_bytes\":{d}," ++
            "\"writer_peak_live_bytes\":{d}," ++
            "\"writer_live_bytes_before_deinit\":{d}," ++
            "\"writer_live_bytes_after_deinit\":{d}," ++
            "\"caller_input_bytes\":{d},\"caller_sink_storage_bytes\":{d}," ++
            "\"caller_oracle_storage_bytes\":{d},\"sink_max_write_bytes\":",
        .{
            RESULT_SCHEMA,
            selection.shape.id(),
            selection.value,
            selection.sink.manifestName(),
            verified,
            result.documents,
            result.elements,
            result.attributes,
            result.namespace_declarations,
            result.text_input_bytes,
            result.text_fragments,
            result.output_bytes,
            result.sink_accepted_bytes,
            result.sink_calls,
            result.sink_flushes,
            result.writer_peak_open_elements,
            result.writer_peak_namespace_bindings,
            result.writer_peak_pending_start_tag_bytes,
            result.writer_peak_retained_capacity_bytes,
            result.writer_final_retained_capacity_bytes,
            result.writer_allocator_allocs,
            result.writer_allocator_resizes,
            result.writer_allocator_remaps,
            result.writer_requested_bytes,
            result.writer_peak_live_bytes,
            result.writer_live_bytes_before_deinit,
            result.writer_live_bytes_after_deinit,
            result.caller_input_bytes,
            result.caller_sink_storage_bytes,
            result.caller_oracle_storage_bytes,
        },
    );
    if (selection.sink.maxWriteBytes()) |maximum| {
        try output.print("{d}", .{maximum});
    } else {
        try output.writeAll("null");
    }
    try output.writeAll("}\n");
    try output.flush();
}

// --- Tests ---

const TEST_HEADER =
    "# z-xml-shape-matrix-v1\n" ++
    "id\tfamily\tlane\tprofile\tinput_models\tseed_fixture\tgenerator\tsize_plan\texpected\toracle\tstatus\tnotes\n";

test "[cli] - [writer adapter]: parses only the documented arguments" {
    const options = parseOptions(&.{
        "z-xml-writer",
        "--verify",
        "bench/shapes.tsv",
        "writer-attributes",
        "16",
        "unbuffered-sink",
    }).?;
    try std.testing.expect(options.verify);
    try std.testing.expectEqualStrings("bench/shapes.tsv", options.manifest);
    try std.testing.expectEqualStrings("writer-attributes", options.shape_id);
    try std.testing.expectEqualStrings("16", options.value);
    try std.testing.expectEqualStrings("unbuffered-sink", options.sink_name);
    try std.testing.expect(parseOptions(&.{
        "z-xml-writer",
        "--verify",
        "--verify",
        "bench/shapes.tsv",
        "writer-attributes",
        "16",
        "unbuffered-sink",
    }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-writer",
        "--unknown",
        "bench/shapes.tsv",
        "writer-attributes",
        "16",
        "unbuffered-sink",
    }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-writer",
        "bench/shapes.tsv",
        "writer-attributes",
        "16",
    }) == null);
}

test "[unit] - [writer adapter manifest]: selects every retained shape and rejects drift" {
    const manifest = TEST_HEADER ++
        "writer-attributes\ta\twriter\twriter-xml10-namespaces\tbuffered-sink,unbuffered-sink\t-\twriter-attributes\tattributes:2\temit\twriter-output-v1\tready\ta\n" ++
        "writer-unchanged-text\tt\twriter\twriter-xml10-namespaces\tbuffered-sink,unbuffered-sink\t-\twriter-unchanged-text\t4k\temit\twriter-output-v1\tready\tt\n" ++
        "writer-escaped-text\tt\twriter\twriter-xml10-namespaces\tbuffered-sink,unbuffered-sink\t-\twriter-escaped-text\t4k\temit\twriter-output-v1\tready\tt\n" ++
        "writer-fragmented-text\tt\twriter\twriter-xml10-namespaces\tbuffered-sink,unbuffered-sink\t-\twriter-fragmented-text\t4k\temit\twriter-output-v1\tready\tt\n" ++
        "writer-namespace-depth\tn\twriter\twriter-xml10-namespaces\tbuffered-sink,unbuffered-sink\t-\twriter-namespace-depth\tdepth:2\temit\twriter-namespace-output-v1\tready\tn\n" ++
        "writer-short-sink\ts\twriter\twriter-xml10-namespaces\tone-byte-sink,short-sink\t-\twriter-short-sink\t4k\temit\twriter-output-v1\tready\ts\n" ++
        "writer-repeated-documents\tr\twriter\twriter-xml10-namespaces\tbuffered-sink,unbuffered-sink\t-\twriter-repeated-documents\tdocuments:2\temit\twriter-output-v1\tready\tr\n";
    inline for (.{
        .{ "writer-attributes", "2", SinkModel.buffered, @as(usize, 2) },
        .{ "writer-unchanged-text", "4k", SinkModel.unbuffered, @as(usize, 4096) },
        .{ "writer-escaped-text", "4k", SinkModel.buffered, @as(usize, 4096) },
        .{ "writer-fragmented-text", "4k", SinkModel.unbuffered, @as(usize, 4096) },
        .{ "writer-namespace-depth", "2", SinkModel.buffered, @as(usize, 2) },
        .{ "writer-short-sink", "4k", SinkModel.one_byte, @as(usize, 4096) },
        .{ "writer-repeated-documents", "2", SinkModel.unbuffered, @as(usize, 2) },
    }) |case| {
        const selection = try selectManifest(manifest, case[0], case[1], case[2]);
        try std.testing.expectEqual(case[3], selection.amount);
    }
    try std.testing.expectError(
        error.InvalidSelection,
        selectManifest(manifest, "writer-attributes", "2", .short),
    );
    try std.testing.expectError(
        error.InvalidSelection,
        selectManifest(manifest, "writer-attributes", "3", .buffered),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        selectManifest(manifest ++ manifest, "writer-attributes", "2", .buffered),
    );
}

test "[integration] - [writer adapter output]: verifies every shape and sink model" {
    const cases = [_]Selection{
        .{ .shape = .attributes, .value = "2", .amount = 2, .sink = .unbuffered },
        .{ .shape = .unchanged_text, .value = "4", .amount = 4, .sink = .buffered },
        .{ .shape = .escaped_text, .value = "4", .amount = 4, .sink = .unbuffered },
        .{ .shape = .fragmented_text, .value = "4097", .amount = 4097, .sink = .buffered },
        .{ .shape = .namespace_depth, .value = "2", .amount = 2, .sink = .unbuffered },
        .{ .shape = .short_sink, .value = "4", .amount = 4, .sink = .one_byte },
        .{ .shape = .short_sink, .value = "4", .amount = 4, .sink = .short },
        .{ .shape = .repeated_documents, .value = "2", .amount = 2, .sink = .buffered },
    };
    for (cases) |selection| {
        var execution = try execute(std.testing.allocator, selection, true);
        defer execution.deinit();
        try std.testing.expectEqual(execution.result.output_bytes, execution.result.sink_accepted_bytes);
        try std.testing.expectEqual(@as(usize, 0), execution.result.writer_live_bytes_after_deinit);
        const expected_sink_storage: usize = if (selection.sink == .buffered)
            BUFFERED_SINK_BYTES
        else
            0;
        try std.testing.expectEqual(expected_sink_storage, execution.result.caller_sink_storage_bytes);
        try std.testing.expect(execution.result.caller_oracle_storage_bytes != 0);
    }
}

test "[integration] - [writer adapter exact output]: preserves compact syntax" {
    var attributes = try execute(std.testing.allocator, .{
        .shape = .attributes,
        .value = "2",
        .amount = 2,
        .sink = .unbuffered,
    }, true);
    defer attributes.deinit();
    try std.testing.expectEqualStrings(
        DECLARATION ++
            "<root aAAA=\"v&lt;&amp;&quot;&#x9;\" aAAB=\"v&lt;&amp;&quot;&#x9;\"/>",
        attributes.capture[0..@intCast(attributes.result.output_bytes)],
    );

    var namespaces = try execute(std.testing.allocator, .{
        .shape = .namespace_depth,
        .value = "2",
        .amount = 2,
        .sink = .unbuffered,
    }, true);
    defer namespaces.deinit();
    try std.testing.expectEqualStrings(
        DECLARATION ++
            "<p:item xmlns:p=\"urn:even\"><p:item xmlns:p=\"urn:odd\"/></p:item>",
        namespaces.capture[0..@intCast(namespaces.result.output_bytes)],
    );

    var repeated = try execute(std.testing.allocator, .{
        .shape = .repeated_documents,
        .value = "2",
        .amount = 2,
        .sink = .buffered,
    }, true);
    defer repeated.deinit();
    try std.testing.expectEqualStrings(
        (DECLARATION ++ "<root/>") ** 2,
        repeated.capture[0..@intCast(repeated.result.output_bytes)],
    );

    try std.testing.expectError(
        error.OracleMismatch,
        verifyOutput(
            std.testing.allocator,
            .{ .shape = .attributes, .value = "2", .amount = 2, .sink = .unbuffered },
            &.{},
            DECLARATION ++ "<root>unexpected</root>",
        ),
    );
    try std.testing.expectError(
        error.OracleMismatch,
        verifyOutput(
            std.testing.allocator,
            .{ .shape = .unchanged_text, .value = "1", .amount = 1, .sink = .unbuffered },
            "x",
            DECLARATION ++ "<root>x<!--unexpected--></root>",
        ),
    );
    try std.testing.expectError(
        error.OracleMismatch,
        verifyOutput(
            std.testing.allocator,
            .{ .shape = .namespace_depth, .value = "3", .amount = 3, .sink = .unbuffered },
            &.{},
            DECLARATION ++
                "<p:item xmlns:p=\"urn:even\"><p:item xmlns:p=\"urn:odd\"/>" ++
                "<p:item xmlns:p=\"urn:even\"/></p:item>",
        ),
    );
}

test "[unit] - [writer adapter sink]: rejects mismatched accepted bytes" {
    try std.testing.expectError(
        error.InvalidSinkResult,
        validateResult(.{ .output_bytes = 2, .sink_accepted_bytes = 1 }),
    );
    try std.testing.expectError(
        error.InvalidSinkResult,
        validateResult(.{ .writer_live_bytes_after_deinit = 1 }),
    );
}

test "[unit] - [writer adapter sink]: accepts vectors and splats" {
    var buffer: [4]u8 = undefined;
    var capture: [16]u8 = undefined;
    var sink = CountingSink.init(&buffer, &capture, 3);
    try sink.interface.writeAll("xy");
    var data = [_][]const u8{ "ab", "cd" };
    try sink.interface.writeSplatAll(&data, 3);
    try sink.interface.flush();
    try std.testing.expectEqualStrings("xyabcdcdcd", capture[0..sink.capture_len]);
    try std.testing.expectEqual(@as(u64, 10), sink.accepted_bytes);
}
