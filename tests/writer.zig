//! Public Writer output, validation, lifecycle, ownership, and limit tests.

const std = @import("std");
const xml = @import("z_xml");

const ALL_TOKEN_OUTPUT =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ++
    "<!--before--><?prepare root?>" ++
    "<p:root xmlns:p=\"urn:p\" a=\"&quot;&amp;\">" ++
    "plain&lt;&amp;]]&gt;" ++
    "<![CDATA[c]]]]><![CDATA[>d]]>&#xD;" ++
    "<p:child/></p:root><!--after--><?done?>";

const CountingSink = struct {
    interface: std.Io.Writer = .{
        .vtable = &.{
            .drain = drain,
            .flush = flush,
        },
        .buffer = &.{},
    },
    written_bytes: usize = 0,
    flush_count: usize = 0,

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        std.debug.assert(writer.end == 0);
        const self: *CountingSink = @alignCast(@fieldParentPtr("interface", writer));
        const written = std.Io.Writer.countSplat(data, splat);
        self.written_bytes += written;
        return written;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *CountingSink = @alignCast(@fieldParentPtr("interface", writer));
        self.flush_count += 1;
    }
};

const OneByteSink = struct {
    interface: std.Io.Writer = .{
        .vtable = &.{ .drain = drain },
        .buffer = &.{},
    },
    storage: [ALL_TOKEN_OUTPUT.len]u8 = undefined,
    len: usize = 0,
    drain_count: usize = 0,

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        std.debug.assert(writer.end == 0);
        std.debug.assert(data.len == 1);
        std.debug.assert(splat == 1);
        const self: *OneByteSink = @alignCast(@fieldParentPtr("interface", writer));
        if (self.len == self.storage.len) return error.WriteFailed;
        self.storage[self.len] = data[0][0];
        self.len += 1;
        self.drain_count += 1;
        return 1;
    }
};

fn writeAllTokenClasses(writer: *xml.Writer) xml.WriterError!void {
    try writer.startDocument();
    try writer.comment("before");
    try writer.processingInstruction("prepare", "root");
    try writer.startElement("p:root");
    try writer.namespace("p", "urn:p");
    try writer.attribute("a", "\"&");
    try writer.text("plain<&]]");
    try writer.text(">");
    try writer.cdata("c]]>d\r");
    try writer.startElement("p:child");
    try writer.endElement();
    try writer.endElement();
    try writer.comment("after");
    try writer.processingInstruction("done", "");
    try writer.endDocument();
}

fn writerAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var sink: CountingSink = .{};
    var writer = try xml.Writer.init(allocator, &sink.interface, .{});
    defer writer.deinit();

    try writeAllTokenClasses(&writer);
}

fn expectExpandedName(
    name: xml.Name,
    raw: []const u8,
    prefix: ?[]const u8,
    local: []const u8,
    namespace_uri: ?[]const u8,
) !void {
    try std.testing.expectEqualStrings(raw, name.raw);
    const expanded = name.expanded orelse return error.MissingExpandedName;
    if (prefix) |expected| {
        try std.testing.expectEqualStrings(expected, expanded.prefix.?);
    } else {
        try std.testing.expect(expanded.prefix == null);
    }
    try std.testing.expectEqualStrings(local, expanded.local);
    if (namespace_uri) |expected| {
        try std.testing.expectEqualStrings(expected, expanded.namespace_uri.?);
    } else {
        try std.testing.expect(expanded.namespace_uri == null);
    }
}

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

test "[property] - [writer sink]: handles one-byte progress and every failure offset" {
    {
        var sink: OneByteSink = .{};
        var writer = try xml.Writer.init(std.testing.allocator, &sink.interface, .{});
        defer writer.deinit();

        try writeAllTokenClasses(&writer);

        try std.testing.expectEqualStrings(ALL_TOKEN_OUTPUT, sink.storage[0..sink.len]);
        try std.testing.expectEqual(ALL_TOKEN_OUTPUT.len, sink.drain_count);
        try std.testing.expectEqual(@as(?u64, ALL_TOKEN_OUTPUT.len), writer.byteOffset());
    }

    for (0..ALL_TOKEN_OUTPUT.len) |capacity| {
        var output_buffer: [ALL_TOKEN_OUTPUT.len]u8 = undefined;
        var output = std.Io.Writer.fixed(output_buffer[0..capacity]);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{});
        defer writer.deinit();

        try std.testing.expectError(error.WriteFailed, writeAllTokenClasses(&writer));
        try std.testing.expectEqualStrings(
            ALL_TOKEN_OUTPUT[0..capacity],
            output.buffered(),
        );
        try std.testing.expectEqual(@as(?u64, null), writer.byteOffset());

        try std.testing.expectError(error.WriteFailed, writer.endDocument());
        try std.testing.expectEqual(@as(?u64, null), writer.byteOffset());
        try std.testing.expectEqualStrings(
            ALL_TOKEN_OUTPUT[0..capacity],
            output.buffered(),
        );
    }
}

test "[integration] - [writer namespaces]: writes scoped names that Reader resolves exactly" {
    const outer_namespace = "urn:outer&one";
    const expected =
        "<?xml version=\"1.1\" encoding=\"UTF-8\"?>" ++
        "<root xmlns=\"urn:outer&amp;one\" value=\"0\" xmlns:p=\"urn:p\" " ++
        "xmlns:xml=\"http://www.w3.org/XML/1998/namespace\" " ++
        "p:value=\"1\" xml:lang=\"en\">" ++
        "<p:child xmlns=\"urn:inner\" xmlns:p=\"urn:inner-p\" p:value=\"2\">" ++
        "<leaf xmlns=\"\"/><plain xmlns:p=\"\"/></p:child><p:child/></root>";
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .version = .xml11,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.namespace(null, outer_namespace);
    try writer.attribute("value", "0");
    try writer.namespace("p", "urn:p");
    try writer.namespace("xml", "http://www.w3.org/XML/1998/namespace");
    try writer.attribute("p:value", "1");
    try writer.attribute("xml:lang", "en");
    try writer.startElement("p:child");
    try writer.namespace(null, "urn:inner");
    try writer.namespace("p", "urn:inner-p");
    try writer.attribute("p:value", "2");
    try writer.startElement("leaf");
    try writer.namespace(null, "");
    try writer.endElement();
    try writer.startElement("plain");
    try writer.namespace("p", "");
    try writer.endElement();
    try writer.endElement();
    try writer.startElement("p:child");
    try writer.endElement();
    try writer.endElement();
    try writer.endDocument();

    try std.testing.expectEqualStrings(expected, output.buffered());
    try std.testing.expectEqual(@as(usize, 0), writer.memoryUsage().namespace_binding_count);
    try std.testing.expectEqual(@as(usize, 0), writer.memoryUsage().namespace_bytes);

    const ExpectedElement = struct {
        raw: []const u8,
        prefix: ?[]const u8 = null,
        local: []const u8,
        namespace_uri: ?[]const u8 = null,
    };
    const expected_elements = [_]ExpectedElement{
        .{ .raw = "root", .local = "root", .namespace_uri = outer_namespace },
        .{
            .raw = "p:child",
            .prefix = "p",
            .local = "child",
            .namespace_uri = "urn:inner-p",
        },
        .{ .raw = "leaf", .local = "leaf" },
        .{ .raw = "plain", .local = "plain", .namespace_uri = "urn:inner" },
        .{
            .raw = "p:child",
            .prefix = "p",
            .local = "child",
            .namespace_uri = "urn:p",
        },
    };
    var parser = try xml.Reader.init(std.testing.allocator, .{ .slice = output.buffered() }, .{});
    defer parser.deinit();
    var start_index: usize = 0;
    while (try parser.next()) |event| switch (event.data) {
        .start_element => |element| {
            const expected_element = expected_elements[start_index];
            try expectExpandedName(
                element.name,
                expected_element.raw,
                expected_element.prefix,
                expected_element.local,
                expected_element.namespace_uri,
            );
            switch (start_index) {
                0 => {
                    try std.testing.expectEqual(@as(usize, 3), element.attributes.len);
                    try expectExpandedName(element.attributes[0].name, "value", null, "value", null);
                    try expectExpandedName(
                        element.attributes[1].name,
                        "p:value",
                        "p",
                        "value",
                        "urn:p",
                    );
                    try expectExpandedName(
                        element.attributes[2].name,
                        "xml:lang",
                        "xml",
                        "lang",
                        "http://www.w3.org/XML/1998/namespace",
                    );
                },
                1 => {
                    try std.testing.expectEqual(@as(usize, 1), element.attributes.len);
                    try expectExpandedName(
                        element.attributes[0].name,
                        "p:value",
                        "p",
                        "value",
                        "urn:inner-p",
                    );
                },
                else => try std.testing.expectEqual(@as(usize, 0), element.attributes.len),
            }
            start_index += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(expected_elements.len, start_index);
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
        try writer.attribute("xmlns", "urn:default");
        try writer.attribute("xmlns:p", "urn:p");
        try writer.startElement("a\xf3\xaf\xbf\xbf");
        try writer.endElement();
        try writer.endElement();
        try writer.endDocument();

        try std.testing.expectEqualStrings(
            "<π:r a:β=\"value\" xmlns=\"urn:default\" " ++
                "xmlns:p=\"urn:p\"><a\xf3\xaf\xbf\xbf/></π:r>",
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

test "[failure] - [writer namespaces]: rejects illegal declarations before output" {
    const Case = struct {
        prefix: ?[]const u8,
        namespace_uri: []const u8,
        expected: xml.WriterError,
    };
    const cases = [_]Case{
        .{ .prefix = "", .namespace_uri = "urn:test", .expected = error.InvalidName },
        .{ .prefix = "a:b", .namespace_uri = "urn:test", .expected = error.InvalidName },
        .{ .prefix = "xmlns", .namespace_uri = "urn:test", .expected = error.InvalidNamespace },
        .{ .prefix = "xml", .namespace_uri = "urn:test", .expected = error.InvalidNamespace },
        .{
            .prefix = "p",
            .namespace_uri = "http://www.w3.org/XML/1998/namespace",
            .expected = error.InvalidNamespace,
        },
        .{
            .prefix = "p",
            .namespace_uri = "http://www.w3.org/2000/xmlns/",
            .expected = error.InvalidNamespace,
        },
        .{ .prefix = "p", .namespace_uri = "", .expected = error.InvalidNamespace },
        .{
            .prefix = null,
            .namespace_uri = "http://www.w3.org/XML/1998/namespace",
            .expected = error.InvalidNamespace,
        },
        .{ .prefix = "p", .namespace_uri = "\x00", .expected = error.InvalidCharacter },
    };

    for (cases) |case| {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try std.testing.expectError(
            case.expected,
            writer.namespace(case.prefix, case.namespace_uri),
        );
        try std.testing.expectEqualStrings("", output.buffered());
    }
}

test "[failure] - [writer namespaces]: rejects malformed reserved and unbound names" {
    const Case = struct {
        name: []const u8,
        attribute: bool = false,
        release: bool = false,
    };
    const cases = [_]Case{
        .{ .name = "a:b:c" },
        .{ .name = "xmlns:root" },
        .{ .name = "p:root", .release = true },
        .{ .name = "a:b:c", .attribute = true },
        .{ .name = "xmlns", .attribute = true },
        .{ .name = "xmlns:value", .attribute = true },
        .{ .name = "p:value", .attribute = true, .release = true },
    };

    for (cases) |case| {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
        });
        defer writer.deinit();

        try writer.startDocument();
        if (case.attribute) {
            try writer.startElement("root");
            if (case.release) {
                try writer.attribute(case.name, "value");
                try std.testing.expectError(error.InvalidNamespace, writer.endElement());
            } else {
                try std.testing.expectError(
                    error.InvalidNamespace,
                    writer.attribute(case.name, "value"),
                );
            }
        } else if (case.release) {
            try writer.startElement(case.name);
            try std.testing.expectError(error.InvalidNamespace, writer.endElement());
        } else {
            try std.testing.expectError(error.InvalidNamespace, writer.startElement(case.name));
        }
        try std.testing.expectEqualStrings("", output.buffered());
    }
}

test "[failure] - [writer namespaces]: rejects duplicate declarations and expanded attributes" {
    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try writer.namespace("p", "urn:one");
        try std.testing.expectError(
            error.InvalidNamespace,
            writer.namespace("p", "urn:two"),
        );
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
        try writer.namespace("a", "urn:same");
        try writer.namespace("b", "urn:same");
        try writer.attribute("a:value", "one");
        try writer.attribute("b:value", "two");
        try std.testing.expectError(error.DuplicateAttribute, writer.endElement());
        try std.testing.expectEqualStrings("", output.buffered());
    }
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

test "[integration] - [writer argument lifetime]: copies names attributes and namespaces" {
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    var element_name = [_]u8{ 'p', ':', 'r', 'o', 'o', 't' };
    var attribute_name = [_]u8{ 'p', ':', 'a' };
    var attribute_value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var prefix = [_]u8{'p'};
    var namespace_uri = [_]u8{ 'u', 'r', 'n', ':', 't', 'e', 's', 't' };
    try writer.startDocument();
    try writer.startElement(&element_name);
    try writer.attribute(&attribute_name, &attribute_value);
    try writer.namespace(&prefix, &namespace_uri);
    @memset(&element_name, 'x');
    @memset(&attribute_name, 'x');
    @memset(&attribute_value, 'x');
    @memset(&prefix, 'x');
    @memset(&namespace_uri, 'x');
    try writer.endElement();
    try writer.endDocument();

    try std.testing.expectEqualStrings(
        "<p:root p:a=\"value\" xmlns:p=\"urn:test\"/>",
        output.buffered(),
    );
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

test "[edge] - [writer limits]: accepts structural boundaries and rejects one over" {
    {
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_open_name_bytes = 2 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("r");
        try writer.startElement("c");
        try writer.endElement();
        try writer.endElement();
        try writer.endDocument();
        try std.testing.expectEqualStrings("<r><c/></r>", output.buffered());
    }
    {
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_open_name_bytes = 1 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.comment("before");
        try writer.startElement("r");
        try std.testing.expectError(error.WriterLimit, writer.startElement("c"));
        try std.testing.expectEqual(@as(usize, 1), writer.memoryUsage().open_name_bytes);
        try std.testing.expectEqual(@as(?u64, "<!--before-->".len), writer.byteOffset());
        try std.testing.expectEqualStrings("<!--before-->", output.buffered());
    }
    {
        var output_buffer: [128]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_name_bytes = 1 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.processingInstruction("t", "");
        try writer.startElement("r");
        try writer.namespace("p", "u");
        try writer.attribute("a", "v");
        try writer.endElement();
        try writer.endDocument();
        try std.testing.expectEqualStrings(
            "<?t?><r xmlns:p=\"u\" a=\"v\"/>",
            output.buffered(),
        );
    }

    const NameOperation = enum { element, attribute, namespace, instruction };
    const operations = [_]NameOperation{ .element, .attribute, .namespace, .instruction };
    for (operations) |operation| {
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_name_bytes = 1 },
        });
        defer writer.deinit();

        try writer.startDocument();
        const result: xml.WriterError!void = switch (operation) {
            .element => writer.startElement("rr"),
            .attribute => attribute: {
                try writer.startElement("r");
                break :attribute writer.attribute("aa", "v");
            },
            .namespace => namespace: {
                try writer.startElement("r");
                break :namespace writer.namespace("pp", "u");
            },
            .instruction => writer.processingInstruction("tt", ""),
        };
        try std.testing.expectError(error.WriterLimit, result);
        try std.testing.expectEqualStrings("", output.buffered());
    }
    {
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_attributes_per_element = 1 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("r");
        try writer.attribute("a", "1");
        try std.testing.expectError(error.WriterLimit, writer.attribute("b", "2"));
        try std.testing.expectEqual(@as(usize, 1), writer.memoryUsage().pending_attribute_count);
        try std.testing.expectEqualStrings("", output.buffered());
    }
}

test "[edge] - [writer pending tag]: includes closing delimiters in its byte limit" {
    const content_tag = "<p:r xmlns:p=\"u&amp;v\" p:a=\"&quot;\">";
    const empty_tag = "<p:r xmlns:p=\"u&amp;v\" p:a=\"&quot;\"/>";

    {
        var output_buffer: [128]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_pending_start_tag_bytes = content_tag.len },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("p:r");
        try writer.namespace("p", "u&v");
        try writer.attribute("p:a", "\"");
        try writer.text("");
        try writer.endElement();
        try writer.endDocument();
        try std.testing.expectEqualStrings(content_tag ++ "</p:r>", output.buffered());
    }
    {
        var output_buffer: [128]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_pending_start_tag_bytes = content_tag.len - 1 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("p:r");
        try writer.namespace("p", "u&v");
        try std.testing.expectError(error.WriterLimit, writer.attribute("p:a", "\""));
        try std.testing.expectEqual(@as(?u64, 0), writer.byteOffset());
        try std.testing.expectEqualStrings("", output.buffered());
    }
    {
        var output_buffer: [128]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_pending_start_tag_bytes = empty_tag.len },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("p:r");
        try writer.namespace("p", "u&v");
        try writer.attribute("p:a", "\"");
        try writer.endElement();
        try writer.endDocument();
        try std.testing.expectEqualStrings(empty_tag, output.buffered());
    }
    {
        var output_buffer: [128]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_pending_start_tag_bytes = content_tag.len },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("p:r");
        try writer.namespace("p", "u&v");
        try writer.attribute("p:a", "\"");
        try std.testing.expectError(error.WriterLimit, writer.endElement());
        try std.testing.expectEqualStrings("", output.buffered());
    }
    {
        var output_buffer: [16]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_pending_start_tag_bytes = 2 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try std.testing.expectError(error.WriterLimit, writer.startElement("r"));
        try std.testing.expectEqualStrings("", output.buffered());
    }
}

test "[edge] - [writer namespace limits]: bounds declarations and binding bytes" {
    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_namespace_declarations_per_element = 1 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try writer.namespace("p", "urn:p");
        try std.testing.expectError(error.WriterLimit, writer.namespace("q", "urn:q"));
        try std.testing.expectEqualStrings("", output.buffered());
    }
    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_namespace_binding_bytes = 6 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("p:r");
        try writer.namespace("p", "urn:p");
        try std.testing.expectEqual(@as(usize, 6), writer.memoryUsage().namespace_bytes);
        try writer.endElement();
        try writer.endDocument();
        try std.testing.expectEqualStrings("<p:r xmlns:p=\"urn:p\"/>", output.buffered());
    }
    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_namespace_binding_bytes = 5 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try std.testing.expectError(error.WriterLimit, writer.namespace("p", "urn:p"));
        try std.testing.expectEqualStrings("", output.buffered());
    }
    {
        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var writer = try xml.Writer.init(std.testing.allocator, &output, .{
            .emit_declaration = false,
            .limits = .{ .max_active_namespace_bindings = 1 },
        });
        defer writer.deinit();

        try writer.startDocument();
        try writer.startElement("root");
        try writer.namespace("p", "urn:p");
        try writer.startElement("child");
        try std.testing.expectError(error.WriterLimit, writer.namespace("q", "urn:q"));
        try std.testing.expectEqualStrings("<root xmlns:p=\"urn:p\">", output.buffered());
    }
}

test "[property] - [writer namespace memory]: sibling declarations roll back with scope" {
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var writer = try xml.Writer.init(std.testing.allocator, &output, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.namespace("p", "urn:outer");
    const root_bytes = writer.memoryUsage().namespace_bytes;
    var scoped_capacity: ?usize = null;
    for (0..32) |_| {
        try writer.startElement("p:child");
        try writer.namespace("p", "urn:child");
        const scoped_usage = writer.memoryUsage();
        try std.testing.expectEqual(@as(usize, 2), scoped_usage.namespace_binding_count);
        try std.testing.expect(scoped_usage.namespace_bytes > root_bytes);
        if (scoped_capacity) |expected| {
            try std.testing.expectEqual(expected, scoped_usage.retained_capacity_bytes);
        } else {
            scoped_capacity = scoped_usage.retained_capacity_bytes;
        }
        try writer.endElement();
        try std.testing.expectEqual(@as(usize, 1), writer.memoryUsage().namespace_binding_count);
        try std.testing.expectEqual(root_bytes, writer.memoryUsage().namespace_bytes);
    }
    try writer.endElement();
    try writer.endDocument();
    try std.testing.expectEqual(@as(usize, 0), writer.memoryUsage().namespace_binding_count);
    try std.testing.expectEqual(@as(usize, 0), writer.memoryUsage().namespace_bytes);
}

test "[property] - [writer memory]: stays bounded across output and construction" {
    const iteration_count = 128;
    const text: [1024]u8 = @splat('x');
    const root_start = "<root xmlns:p=\"urn:p\">";
    const child_start = "<p:item id=\"1\">";
    const child_end = "</p:item>";
    const root_end = "</root>";
    const expected_bytes = root_start.len +
        iteration_count * (child_start.len + text.len + child_end.len) +
        root_end.len;

    var sink: CountingSink = .{};
    var writer = try xml.Writer.init(std.testing.allocator, &sink.interface, .{
        .emit_declaration = false,
        .limits = .{ .max_retained_bytes = 4096 },
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.namespace("p", "urn:p");
    var retained_capacity: ?usize = null;
    for (0..iteration_count) |_| {
        try writer.startElement("p:item");
        try writer.attribute("id", "1");
        try writer.text(&text);
        try writer.endElement();

        const usage = writer.memoryUsage();
        if (retained_capacity) |expected| {
            try std.testing.expectEqual(expected, usage.retained_capacity_bytes);
        } else {
            retained_capacity = usage.retained_capacity_bytes;
        }
        try std.testing.expect(usage.retained_capacity_bytes <= 4096);
    }
    try writer.endElement();
    try writer.endDocument();

    try std.testing.expectEqual(expected_bytes, sink.written_bytes);
    try std.testing.expectEqual(@as(?u64, expected_bytes), writer.byteOffset());

    for (0..32) |_| {
        var repeated_sink: CountingSink = .{};
        var repeated = try xml.Writer.init(
            std.testing.allocator,
            &repeated_sink.interface,
            .{ .emit_declaration = false },
        );
        defer repeated.deinit();

        try repeated.startDocument();
        try repeated.startElement("r");
        try repeated.endElement();
        try repeated.endDocument();
        try std.testing.expectEqual(@as(usize, 4), repeated_sink.written_bytes);
    }
}

test "[failure] - [writer allocation]: releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        writerAllocationFailureCase,
        .{},
    );

    var sink: CountingSink = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var writer = try xml.Writer.init(failing.allocator(), &sink.interface, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.comment("before");
    try std.testing.expectError(error.OutOfMemory, writer.startElement("root"));
    try std.testing.expectEqual(@as(?u64, "<!--before-->".len), writer.byteOffset());
    try std.testing.expectEqual(@as(usize, "<!--before-->".len), sink.written_bytes);
    try std.testing.expectError(error.OutOfMemory, writer.endDocument());
    try std.testing.expectEqual(@as(usize, "<!--before-->".len), sink.written_bytes);
}

test "[failure] - [writer allocation]: keeps a pending parent unpublished" {
    const child_name: [1024]u8 = @splat('c');
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .resize_fail_index = 0,
    });
    var writer = try xml.Writer.init(failing_allocator.allocator(), &output, .{
        .emit_declaration = false,
    });
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expectEqual(@as(?u64, 0), writer.byteOffset());

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, writer.startElement(&child_name));
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expectEqual(@as(?u64, 0), writer.byteOffset());
    try std.testing.expectEqual(@as(usize, 1), writer.memoryUsage().open_element_count);
    try std.testing.expectError(error.OutOfMemory, writer.endElement());
    try std.testing.expectEqualStrings("", output.buffered());
}

test "[integration] - [writer ownership]: leaves sink flushing to the caller" {
    var sink: CountingSink = .{};
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
