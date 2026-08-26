//! Public Writer output, validation, lifecycle, ownership, and limit tests.

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

test "[integration] - [writer output]: writes compact XML in call order" {
    const declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
    const prolog = "<!--before--><?prepare root?>";
    const expected = declaration ++ prolog ++
        "<root id=\"1\"><child>value<![CDATA[raw]]><!--inside--><?step done?></child>" ++
        "</root><!--after--><?final?>";
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
    defer writer.deinit();

    try writer.startDocument();
    try writer.comment("before");
    try writer.processingInstruction("prepare", "root");
    try writer.startElement("root");
    try std.testing.expectEqual(@as(?u64, (declaration ++ prolog).len), writer.byteOffset());
    try writer.attribute("id", "1");
    try std.testing.expectEqual(@as(usize, 1), writer.memoryUsage().pending_attribute_count);
    try writer.startElement("child");
    try std.testing.expectEqual(
        @as(?u64, (declaration ++ prolog ++ "<root id=\"1\">").len),
        writer.byteOffset(),
    );
    try std.testing.expectEqual(@as(usize, 2), writer.memoryUsage().open_element_count);
    try writer.text("value");
    try writer.cdata("raw");
    try writer.comment("inside");
    try writer.processingInstruction("step", "done");
    try writer.endElement();
    try writer.endElement();
    try std.testing.expectEqual(@as(usize, 0), writer.memoryUsage().open_element_count);
    try writer.comment("after");
    try writer.processingInstruction("final", "");
    try writer.endDocument();

    try std.testing.expectEqualStrings(expected, output.buffered());
    try std.testing.expectEqual(@as(?u64, expected.len), writer.byteOffset());
}

test "[property] - [writer declaration]: emits each configured declaration" {
    const Case = struct {
        options: xml.WriterOptions,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{
            .options = .{},
            .expected = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><r/>",
        },
        .{
            .options = .{ .standalone = true },
            .expected = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><r/>",
        },
        .{
            .options = .{ .standalone = false },
            .expected = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?><r/>",
        },
        .{
            .options = .{ .version = .xml11 },
            .expected = "<?xml version=\"1.1\" encoding=\"UTF-8\"?><r/>",
        },
        .{
            .options = .{ .version = .xml11, .standalone = true },
            .expected = "<?xml version=\"1.1\" encoding=\"UTF-8\" standalone=\"yes\"?><r/>",
        },
        .{
            .options = .{ .emit_declaration = false },
            .expected = "<r/>",
        },
    };

    for (cases) |case| {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, case.options);
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("r");
        try writer.endElement();
        try writer.endDocument();

        try std.testing.expectEqualStrings(case.expected, output.buffered());
        try std.testing.expectEqual(@as(?u64, case.expected.len), writer.byteOffset());
    }
}

test "[property] - [writer escaping]: preserves attribute text and CDATA values" {
    const expected =
        "<r a=\"&quot;&lt;&amp;&#x9;&#xA;&#xD;é\">" ++
        "a&amp;&lt;>]]&gt;&#xD;" ++
        "<![CDATA[x]]]]><![CDATA[>y]]>&#xD;<![CDATA[]]>" ++
        "</r>";
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("r");
    try writer.attribute("a", "\"<&\t\n\ré");
    try writer.text("a&<>");
    try writer.text("]]");
    try writer.text(">");
    try writer.text("\r");
    try writer.cdata("x]]>y\r");
    try writer.cdata("");
    try writer.endElement();
    try writer.endDocument();

    try std.testing.expectEqualStrings(expected, output.buffered());
}

test "[edge] - [writer content]: empty calls close pending start tags" {
    const expected =
        "<root><text></text><cdata><![CDATA[]]></cdata>" ++
        "<comment><!----></comment><pi><?target?></pi></root>";
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.startElement("text");
    try writer.text("");
    try writer.endElement();
    try writer.startElement("cdata");
    try writer.cdata("");
    try writer.endElement();
    try writer.startElement("comment");
    try writer.comment("");
    try writer.endElement();
    try writer.startElement("pi");
    try writer.processingInstruction("target", "");
    try writer.endElement();
    try writer.endElement();
    try writer.endDocument();

    try std.testing.expectEqualStrings(expected, output.buffered());
}

test "[property] - [XML 1.1 writer]: references restricted and normalized characters" {
    const expected =
        "<?xml version=\"1.1\" encoding=\"UTF-8\"?>" ++
        "<r a=\"&#x1;&#x7F;&#x85;&#x2028;\">" ++
        "&#x1;&#x7F;&#x85;&#x2028;" ++
        "<![CDATA[a]]>&#x1;<![CDATA[b]]>&#x85;<![CDATA[c]]>" ++
        "</r>";
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .version = .xml11,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("r");
    try writer.attribute("a", "\x01\x7f\xc2\x85\xe2\x80\xa8");
    try writer.text("\x01\x7f\xc2\x85\xe2\x80\xa8");
    try writer.cdata("a\x01b\xc2\x85c");
    try writer.endElement();
    try writer.endDocument();

    try std.testing.expectEqualStrings(expected, output.buffered());
}

test "[property] - [writer names]: accepts XML names and rejects malformed names" {
    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .namespaces = .raw,
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("π:r");
        try writer.attribute("a:β", "value");
        try writer.startElement("a\xf3\xaf\xbf\xbf");
        try writer.endElement();
        try writer.endElement();
        try writer.endDocument();

        try std.testing.expectEqualStrings(
            "<π:r a:β=\"value\"><a\xf3\xaf\xbf\xbf/></π:r>",
            output.buffered(),
        );
    }

    const invalid_names = [_][]const u8{
        "",
        "1root",
        "root name",
        "root/",
        "\xc0",
        "\xef\xbf\xbe",
        "\xf3\xb0\x80\x80",
    };
    for (invalid_names) |name| {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
        });
        defer writer.deinit();

        try writer.startDocument();
        try std.testing.expectError(error.InvalidName, writer.startElement(name));
        try std.testing.expectEqualStrings("", output.buffered());
    }

    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try std.testing.expectError(error.InvalidName, writer.attribute("bad name", "value"));
        try std.testing.expectEqualStrings("", output.buffered());
    }
    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try std.testing.expectError(
            error.InvalidName,
            writer.processingInstruction("1target", "data"),
        );
        try std.testing.expectEqualStrings("", output.buffered());
    }
}

test "[failure] - [writer characters]: rejects malformed and forbidden XML characters" {
    const Operation = enum {
        attribute,
        text,
        cdata,
        comment,
        processing_instruction,
    };
    const operations = [_]Operation{
        .attribute,
        .text,
        .cdata,
        .comment,
        .processing_instruction,
    };
    const invalid_values = [_][]const u8{
        "\x00",
        "\x01",
        "\xc0",
        "\xef\xbf\xbe",
    };

    for (operations) |operation| {
        for (invalid_values) |value| {
            var output_buffer: [256]u8 = undefined;
            var output = std.Io.Writer.fixed(&output_buffer);
            var writer = try xml.Writer.init(std.testing.allocator, &output, .{
                .emit_declaration = false,
            });
            defer writer.deinit();

            try writer.startDocument();
            if (operation == .attribute or operation == .text or operation == .cdata) {
                try writer.startElement("root");
            }
            const result: xml.WriterError!void = switch (operation) {
                .attribute => writer.attribute("a", value),
                .text => writer.text(value),
                .cdata => writer.cdata(value),
                .comment => writer.comment(value),
                .processing_instruction => writer.processingInstruction("target", value),
            };
            try std.testing.expectError(error.InvalidCharacter, result);
            try std.testing.expectEqualStrings("", output.buffered());
        }
    }

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
        .version = .xml11,
    });
    defer writer.deinit();
    try writer.startDocument();
    try writer.startElement("root");
    try std.testing.expectError(error.InvalidCharacter, writer.text("\x00"));
    try std.testing.expectEqualStrings("", output.buffered());
}

test "[failure] - [writer markup]: rejects invalid comments and processing instructions" {
    const CommentCase = struct {
        options: xml.WriterOptions = .{ .emit_declaration = false },
        value: []const u8,
        expected: xml.WriterError,
    };
    const comment_cases = [_]CommentCase{
        .{ .value = "a--b", .expected = error.InvalidComment },
        .{ .value = "a-", .expected = error.InvalidComment },
        .{ .value = "a\rb", .expected = error.InvalidComment },
        .{
            .options = .{ .emit_declaration = false, .version = .xml11 },
            .value = "a\xc2\x85b",
            .expected = error.InvalidComment,
        },
        .{
            .options = .{ .emit_declaration = false, .version = .xml11 },
            .value = "a\x01b",
            .expected = error.InvalidCharacter,
        },
    };
    for (comment_cases) |case| {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, case.options);
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try std.testing.expectError(case.expected, writer.comment(case.value));
        try std.testing.expectEqualStrings("", output.buffered());
    }

    const InstructionCase = struct {
        options: xml.WriterOptions = .{ .emit_declaration = false },
        target: []const u8 = "target",
        data: []const u8,
        expected: xml.WriterError,
    };
    const instruction_cases = [_]InstructionCase{
        .{ .target = "xml", .data = "", .expected = error.InvalidProcessingInstruction },
        .{ .target = "XmL", .data = "", .expected = error.InvalidProcessingInstruction },
        .{ .data = "a?>b", .expected = error.InvalidProcessingInstruction },
        .{ .data = "a\rb", .expected = error.InvalidProcessingInstruction },
        .{
            .options = .{ .emit_declaration = false, .version = .xml11 },
            .data = "a\xe2\x80\xa8b",
            .expected = error.InvalidProcessingInstruction,
        },
        .{
            .options = .{ .emit_declaration = false, .version = .xml11 },
            .target = "xml",
            .data = "\x01",
            .expected = error.InvalidCharacter,
        },
    };
    for (instruction_cases) |case| {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, case.options);
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try std.testing.expectError(
            case.expected,
            writer.processingInstruction(case.target, case.data),
        );
        try std.testing.expectEqualStrings("", output.buffered());
    }
}

test "[failure] - [writer attributes]: rejects duplicate raw names" {
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
        .namespaces = .raw,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.attribute("a", "one");
    try std.testing.expectError(error.DuplicateAttribute, writer.attribute("a", "two"));
    try std.testing.expectEqualStrings("", output.buffered());
}

test "[failure] - [writer raw names]: rejects namespace declarations" {
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
        .namespaces = .raw,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try std.testing.expectError(
        error.InvalidNamespace,
        writer.namespace(null, "urn:test"),
    );
    try std.testing.expectEqualStrings("", output.buffered());
}

test "[failure] - [writer document]: rejects unfinished output without publishing a pending tag" {
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.attribute("a", "value");
    try std.testing.expectError(error.InvalidState, writer.endDocument());
    try std.testing.expectEqualStrings("", output.buffered());
}

test "[integration] - [writer argument lifetime]: copies retained names and attributes" {
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    var element_name = [_]u8{ 'r', 'o', 'o', 't' };
    var attribute_name = [_]u8{'a'};
    var attribute_value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    try writer.startDocument();
    try writer.startElement(&element_name);
    try writer.attribute(&attribute_name, &attribute_value);
    @memset(&element_name, 'x');
    @memset(&attribute_name, 'x');
    @memset(&attribute_value, 'x');
    try writer.endElement();
    try writer.endDocument();

    try std.testing.expectEqualStrings("<root a=\"value\"/>", output.buffered());
}

test "[integration] - [writer round trip]: Reader preserves core output values" {
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.attribute("a", "one & two\tthree");
    try writer.text("before<&");
    try writer.cdata("middle]]>raw");
    try writer.startElement("child");
    try writer.endElement();
    try writer.text("after\r");
    try writer.endElement();
    try writer.endDocument();

    var parser = try xml.Reader.init(std.testing.allocator, .{ .slice = output.buffered() }, .{});
    defer parser.deinit();
    var starts: usize = 0;
    var ends: usize = 0;
    var attributes: usize = 0;
    var text_buffer: [256]u8 = undefined;
    var text = std.Io.Writer.fixed(&text_buffer);
    while (try parser.next()) |event| switch (event.data) {
        .start_element => |element| {
            starts += 1;
            attributes += element.attributes.len;
            if (std.mem.eql(u8, element.name.raw, "root")) {
                try std.testing.expectEqual(@as(usize, 1), element.attributes.len);
                try std.testing.expectEqualStrings(
                    "one & two\tthree",
                    element.attributes[0].value,
                );
            }
        },
        .end_element => ends += 1,
        .text => |value| try text.writeAll(value.bytes),
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 2), starts);
    try std.testing.expectEqual(@as(usize, 2), ends);
    try std.testing.expectEqual(@as(usize, 1), attributes);
    try std.testing.expectEqualStrings("before<&middle]]>rawafter\r", text.buffered());
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
        try std.testing.expectError(error.InvalidState, writer.namespace(null, "urn:test"));
    }
    {
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();
        try writer.startDocument();
        try std.testing.expectError(error.InvalidState, writer.text("value"));
    }
    {
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();
        try writer.startDocument();
        try std.testing.expectError(error.InvalidState, writer.endElement());
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
        .{ .limits = .{ .max_name_bytes = 0 } },
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
    try std.testing.expectEqual(@as(usize, 1), writer.memoryUsage().open_element_count);
    try std.testing.expectError(error.WriterLimit, writer.endElement());
    try std.testing.expectEqual(@as(usize, 1), writer.memoryUsage().open_element_count);
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
