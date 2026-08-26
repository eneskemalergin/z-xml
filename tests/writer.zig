//! Public Writer lifecycle, ownership, limit, and package-surface tests.

const std = @import("std");
const xml = @import("z_xml");

const FlushSink = struct {
    interface: std.Io.Writer = .{
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
        .buffer = &.{},
    },
    flush_count: usize = 0,

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        std.debug.assert(writer.end == 0);
        return std.Io.Writer.countSplat(data, splat);
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FlushSink = @alignCast(@fieldParentPtr("interface", writer));
        self.flush_count += 1;
    }
};

test "[integration] - [writer surface]: accepts the public lifecycle" {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
    defer writer.deinit();

    try writer.startDocument();
    try writer.comment("before");
    try writer.processingInstruction("prepare", "root");
    try writer.startElement("root");
    try std.testing.expectEqual(@as(?u64, 0), writer.byteOffset());
    try writer.namespace(null, "urn:example");
    try writer.attribute("id", "1");
    try writer.startElement("child");
    try std.testing.expectEqual(@as(usize, 2), writer.memoryUsage().open_element_count);
    try writer.text("value");
    try writer.cdata("raw");
    try writer.comment("inside");
    try writer.processingInstruction("step", "done");
    try writer.endElement();
    try writer.endElement();
    try std.testing.expectEqual(@as(usize, 0), writer.memoryUsage().open_element_count);
    try writer.comment("after");
    try writer.endDocument();
}

test "[failure] - [writer lifecycle]: preserves the first state error" {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
    defer writer.deinit();

    try std.testing.expectError(error.InvalidState, writer.endDocument());
    try std.testing.expectError(error.InvalidState, writer.startDocument());
    try std.testing.expectEqual(@as(?u64, 0), writer.byteOffset());
}

test "[failure] - [writer lifecycle]: rejects calls outside their states" {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);

    {
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();
        try std.testing.expectError(error.InvalidState, writer.startElement("root"));
    }
    {
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();
        try writer.startDocument();
        try std.testing.expectError(error.InvalidState, writer.attribute("id", "1"));
    }
    {
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();
        try writer.startDocument();
        try writer.startElement("root");
        try std.testing.expectError(error.InvalidState, writer.endDocument());
    }
    {
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();
        try writer.startDocument();
        try writer.startElement("root");
        try writer.endElement();
        try std.testing.expectError(error.InvalidState, writer.startElement("second"));
    }
    {
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();
        try writer.startDocument();
        try writer.startElement("root");
        try writer.endElement();
        try writer.endDocument();
        try std.testing.expectError(error.InvalidState, writer.comment("late"));
    }
}

test "[failure] - [writer limits]: rejects invalid options and excess depth" {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);

    const invalid_options = [_]xml.WriterOptions{
        .{ .limits = .{ .max_depth = 0 } },
        .{ .limits = .{ .max_open_name_bytes = 0 } },
        .{ .limits = .{ .max_qname_bytes = 0 } },
        .{ .limits = .{ .max_attributes_per_element = 0 } },
        .{ .limits = .{ .max_namespace_declarations_per_element = 0 } },
        .{ .limits = .{ .max_active_namespace_bindings = 0 } },
        .{ .limits = .{ .max_namespace_binding_bytes = 0 } },
        .{ .limits = .{ .max_pending_start_tag_bytes = 0 } },
        .{ .limits = .{ .max_retained_bytes = 0 } },
        .{ .emit_declaration = false, .standalone = true },
    };
    for (invalid_options) |options| {
        try std.testing.expectError(
            error.InvalidOptions,
            xml.Writer.init(std.testing.allocator, &output, options),
        );
    }

    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .limits = .{ .max_depth = 1 },
    });
    defer writer.deinit();
    try writer.startDocument();
    try writer.startElement("root");
    try std.testing.expectError(error.WriterLimit, writer.startElement("child"));
    try std.testing.expectError(error.WriterLimit, writer.endElement());
}

test "[integration] - [writer ownership]: leaves sink flushing to the caller" {
    var sink: FlushSink = .{};
    var writer = try xml.Writer.init(std.testing.allocator, &sink.interface, .{});
    try writer.startDocument();
    try writer.startElement("root");
    try writer.endElement();
    try writer.endDocument();
    writer.deinit();

    try std.testing.expectEqual(@as(usize, 0), sink.flush_count);
    try sink.interface.flush();
    try std.testing.expectEqual(@as(usize, 1), sink.flush_count);
}
