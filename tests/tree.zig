//! Verifies the public immutable owned-tree contract.

const std = @import("std");
const xml = @import("z_xml");

fn parse(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    input: []const u8,
    tree_options: xml.TreeOptions,
) !xml.Document(config) {
    return parseWithReaderOptions(config, allocator, .{}, input, tree_options);
}

fn parseWithReaderOptions(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    reader_options: xml.Options(config),
    input: []const u8,
    tree_options: xml.TreeOptions,
) !xml.Document(config) {
    var pull = try xml.SliceReader(config).init(allocator, reader_options, input);
    defer pull.deinit();
    return xml.buildTreeFromPull(config, allocator, tree_options, &pull);
}

test "[integration] - [owned tree]: preserves document order and semantic values" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    const input =
        "<?xml version='1.0' standalone='yes'?><!--before--><?go now?>" ++
        "<root a='1 &amp; 2'><child/>text<![CDATA[more]]></root><!--after-->";
    var document = try parse(config, std.testing.allocator, input, .{});
    defer document.deinit();

    try std.testing.expectEqual(xml.NodeKind.document, document.nodeKind(document.root()).?);
    const root = document.documentElement();
    try std.testing.expectEqualStrings("root", document.nodeName(root).?.raw);
    try std.testing.expectEqualStrings("1 & 2", document.attributeByRaw(root, "a").?.value);

    const before = document.firstChild(document.root());
    try std.testing.expectEqual(xml.NodeKind.comment, document.nodeKind(before).?);
    try std.testing.expectEqualStrings("before", document.nodeValue(before).?);
    const instruction = document.nextSibling(before);
    const pi = document.processingInstruction(instruction).?;
    try std.testing.expectEqualStrings("go", pi.target);
    try std.testing.expectEqualStrings("now", pi.data);
    try std.testing.expectEqual(root, document.nextSibling(instruction));

    const child = document.firstChild(root);
    try std.testing.expectEqualStrings("child", document.nodeName(child).?.raw);
    const text = document.nextSibling(child);
    try std.testing.expectEqualStrings("text", document.nodeValue(text).?);
    try std.testing.expectEqual(xml.TextOrigin.character_data, document.textOrigin(text).?);
    const cdata = document.nextSibling(text);
    try std.testing.expectEqualStrings("more", document.nodeValue(cdata).?);
    try std.testing.expectEqual(xml.TextOrigin.cdata, document.textOrigin(cdata).?);
    try std.testing.expectEqualStrings("after", document.nodeValue(document.nextSibling(root)).?);
    var children = document.children(root);
    try std.testing.expectEqual(child, children.next().?);
    try std.testing.expectEqual(text, children.next().?);
    try std.testing.expectEqual(cdata, children.next().?);
    try std.testing.expectEqual(@as(?xml.NodeIndex, null), children.next());

    const declaration = document.xmlDeclaration();
    try std.testing.expectEqualStrings("1.0", declaration.declared_version.?);
    try std.testing.expect(declaration.standalone_declared);
    try std.testing.expect(declaration.standalone);
}

test "[integration] - [owned tree]: preserves XML 1.1 declaration and normalized text" {
    const config = xml.Configs.XML11_NONVALIDATING;
    var document = try parse(
        config,
        std.testing.allocator,
        "<?xml version='1.1'?><root>A\xc2\x85B</root>",
        .{},
    );
    defer document.deinit();

    try std.testing.expectEqual(
        xml.XmlVersion.xml11,
        document.xmlDeclaration().effective_version,
    );
    try std.testing.expectEqualStrings(
        "A\nB",
        document.nodeValue(document.firstChild(document.documentElement())).?,
    );
}

test "[integration] - [owned tree]: joins fragmented comments and processing instructions" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    var reader_options: xml.Options(config) = .{};
    reader_options.limits.max_fragment_bytes = 2;
    var document = try parseWithReaderOptions(
        config,
        std.testing.allocator,
        reader_options,
        "<!--abcdef--><?target abcdef?><r/>",
        .{},
    );
    defer document.deinit();

    const comment = document.firstChild(document.root());
    try std.testing.expectEqualStrings("abcdef", document.nodeValue(comment).?);
    const instruction = document.nextSibling(comment);
    const pi = document.processingInstruction(instruction).?;
    try std.testing.expectEqualStrings("target", pi.target);
    try std.testing.expectEqualStrings("abcdef", pi.data);
}

test "[integration] - [owned tree]: retains detailed DTD reports in source order" {
    const config: xml.Config = .{
        .profile = .xml10_nonvalidating,
        .report = .detailed,
    };
    const input =
        "<!DOCTYPE r [" ++
        "<!ELEMENT r (#PCDATA)>" ++
        "<!ATTLIST r a CDATA #IMPLIED>" ++
        "<!ENTITY e 'value'>" ++
        "<!NOTATION n SYSTEM 'urn:n'>" ++
        "<!ENTITY u SYSTEM 'urn:u' NDATA n>" ++
        "]><r>&e;</r>";
    var document = try parse(config, std.testing.allocator, input, .{});
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 7), document.dtdRecordCount());
    const expected = [_]xml.TreeDtdRecordKind{
        .element,
        .attribute_list,
        .parsed_entity,
        .notation,
        .unparsed_entity,
    };
    for (expected, 0..) |kind, index| {
        try std.testing.expectEqual(kind, document.dtdRecordAt(index).?.kind);
    }
    try std.testing.expectEqualStrings("n", document.dtdRecordAt(4).?.notation_name.?);
    try std.testing.expectEqual(xml.TreeDtdRecordKind.entity_start, document.dtdRecordAt(5).?.kind);
    try std.testing.expectEqual(xml.TreeDtdRecordKind.entity_end, document.dtdRecordAt(6).?.kind);
    try std.testing.expectEqualStrings(
        "value",
        document.nodeValue(document.firstChild(document.documentElement())).?,
    );
}

test "[integration] - [owned tree]: preserves skipped external entity boundaries" {
    const config: xml.Config = .{
        .profile = .xml10_nonvalidating,
        .report = .detailed,
        .external_sources = true,
    };
    const input =
        "<!DOCTYPE r [<!ELEMENT r ANY><!ENTITY e SYSTEM 'urn:e'>]>" ++
        "<r>a&e;b</r>";
    var document = try parse(config, std.testing.allocator, input, .{});
    defer document.deinit();

    const first = document.firstChild(document.documentElement());
    try std.testing.expectEqualStrings("a", document.nodeValue(first).?);
    const second = document.nextSibling(first);
    try std.testing.expectEqualStrings("b", document.nodeValue(second).?);
    const skipped = document.dtdRecordAt(document.dtdRecordCount() - 1).?;
    try std.testing.expectEqual(xml.TreeDtdRecordKind.skipped_entity, skipped.kind);
    try std.testing.expectEqual(xml.SkippedEntityKind.general_entity, skipped.skipped_entity_kind.?);
}

test "[integration] - [owned tree]: retains validating whitespace classification" {
    const config: xml.Config = .{ .profile = .xml10_dtd_validating };
    const input = "<!DOCTYPE r [<!ELEMENT r (x)><!ELEMENT x EMPTY>]><r> \n<x/></r>";
    var document = try parse(config, std.testing.allocator, input, .{});
    defer document.deinit();

    const text = document.firstChild(document.documentElement());
    try std.testing.expect(document.isIgnorableWhitespace(text));
    try std.testing.expectEqual(xml.ValidationStatus.valid, document.validationStatus().?);
}

test "[integration] - [owned tree]: preserves namespaces and default attributes" {
    const config = xml.Configs.XML10_NAMESPACES_NONVALIDATING_INTERNAL;
    const input =
        "<!DOCTYPE p:r [" ++
        "<!ELEMENT p:r EMPTY>" ++
        "<!ATTLIST p:r mode (a|b) 'a'>" ++
        "]><p:r xmlns:p='urn:test' xmlns='urn:default'/>";
    var document = try parse(config, std.testing.allocator, input, .{});
    defer document.deinit();

    const element = document.documentElement();
    const name = document.nodeName(element).?;
    try std.testing.expectEqualStrings("p:r", name.raw);
    try std.testing.expectEqualStrings("p", name.prefix.?);
    try std.testing.expectEqualStrings("r", name.local);
    try std.testing.expectEqualStrings("urn:test", name.namespace_uri.?);
    try std.testing.expectEqual(@as(usize, 2), document.namespaceDeclarationCount(element));
    try std.testing.expectEqualStrings(
        "urn:test",
        document.namespaceDeclarationAt(element, 0).?.namespace_uri,
    );
    try std.testing.expectEqualStrings(
        "urn:default",
        document.namespaceDeclarationAt(element, 1).?.namespace_uri,
    );
    const attribute = document.attributeByExpanded(element, null, "mode").?;
    try std.testing.expectEqualStrings("a", attribute.value);
    try std.testing.expect(!attribute.specified);
    try std.testing.expectEqual(xml.AttributeType.enumeration, attribute.declared_type.?);
    try std.testing.expectEqualStrings("p:r", document.documentType().?.root_name);
}

test "[integration] - [owned tree]: retains event locations when configured" {
    const config = xml.Configs.XML10_UTF8_NO_DTD_LOCATED;
    var document = try parse(config, std.testing.allocator, "\n<r><x/></r>", .{});
    defer document.deinit();

    const root_location = document.location(document.documentElement()).?;
    try std.testing.expectEqual(@as(u64, 1), root_location.byte_offset);
    try std.testing.expectEqual(@as(u64, 2), root_location.line);
    try std.testing.expectEqual(@as(u64, 1), root_location.byte_column);
}

test "[integration] - [owned tree]: owns normalized UTF-16 semantic content" {
    const config = xml.Configs.XML10_NO_DTD;
    const input = [_]u8{
        0xff, 0xfe, '<', 0, 'r', 0, ' ', 0, 'a', 0, '=', 0, '\'', 0,
        'x',  0,    '&', 0, 'a', 0, 'm', 0, 'p', 0, ';', 0, 'y',  0,
        '\'', 0,    '>', 0, 'z', 0, '<', 0, '/', 0, 'r', 0, '>',  0,
    };
    var document = try parse(config, std.testing.allocator, &input, .{});
    defer document.deinit();

    const root = document.documentElement();
    try std.testing.expectEqualStrings("x&y", document.attributeByRaw(root, "a").?.value);
    try std.testing.expectEqualStrings("z", document.nodeValue(document.firstChild(root)).?);
    try std.testing.expectEqual(xml.SourceEncoding.utf16_le, document.xmlDeclaration().source_encoding);
}

test "[property] - [owned tree]: coalescing follows the configured text-origin boundary" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    const input = "<r>a<![CDATA[b]]>c&amp;d</r>";
    var preserved = try parse(config, std.testing.allocator, input, .{});
    defer preserved.deinit();
    const first = preserved.firstChild(preserved.documentElement());
    try std.testing.expectEqualStrings("a", preserved.nodeValue(first).?);
    const second = preserved.nextSibling(first);
    try std.testing.expectEqualStrings("b", preserved.nodeValue(second).?);
    try std.testing.expectEqualStrings("c&d", preserved.nodeValue(preserved.nextSibling(second)).?);

    var merged = try parse(config, std.testing.allocator, input, .{ .preserve_cdata_origin = false });
    defer merged.deinit();
    const text = merged.firstChild(merged.documentElement());
    try std.testing.expectEqualStrings("abc&d", merged.nodeValue(text).?);
    try std.testing.expectEqual(@as(xml.NodeIndex, 0), merged.nextSibling(text));

    var normalized = try parse(
        config,
        std.testing.allocator,
        "<r><![CDATA[a]]>b</r>",
        .{ .preserve_cdata_origin = false },
    );
    defer normalized.deinit();
    const normalized_text = normalized.firstChild(normalized.documentElement());
    try std.testing.expectEqual(xml.TextOrigin.character_data, normalized.textOrigin(normalized_text).?);
}

test "[failure] - [owned tree]: reports independent count and memory limits" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    try std.testing.expectError(
        error.TreeLimit,
        parse(config, std.testing.allocator, "<r><a/></r>", .{
            .limits = .{ .max_nodes = 2 },
        }),
    );
    try std.testing.expectError(
        error.TreeLimit,
        parse(config, std.testing.allocator, "<r a='value'/>", .{
            .limits = .{ .max_string_bytes = 4 },
        }),
    );
    try std.testing.expectError(
        error.TreeLimit,
        parse(config, std.testing.allocator, "<r a='1' b='2'/>", .{
            .limits = .{ .max_attributes = 1 },
        }),
    );
    try std.testing.expectError(
        error.TreeLimit,
        parse(config, std.testing.allocator, "<r><a/><b/></r>", .{
            .limits = .{ .max_children_per_element = 1 },
        }),
    );
    var document_misc = try parse(config, std.testing.allocator, "<!--a--><r/><!--b-->", .{
        .limits = .{ .max_children_per_element = 1 },
    });
    document_misc.deinit();
    try std.testing.expectError(
        error.TreeLimit,
        parse(config, std.testing.allocator, "<r>abcdef</r>", .{
            .limits = .{ .max_coalesced_text_bytes = 5 },
        }),
    );
    try std.testing.expectError(
        error.TreeLimit,
        parse(config, std.testing.allocator, "<r/>", .{
            .limits = .{ .max_tree_bytes = 1 },
        }),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        xml.TreeBuilder(config).init(std.testing.allocator, .{
            .limits = .{ .max_nodes = 0 },
        }),
    );
    try std.testing.expectError(
        error.InvalidXml,
        parse(config, std.testing.allocator, "<r>", .{}),
    );

    const namespace_config = xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD;
    try std.testing.expectError(
        error.TreeLimit,
        parse(namespace_config, std.testing.allocator, "<r xmlns='a' xmlns:p='b'/>", .{
            .limits = .{ .max_namespace_declarations = 1 },
        }),
    );
}

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    var document = try parse(
        xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD,
        allocator,
        "<!--x--><r xmlns='u' a='v'><x/>text<?p d?></r>",
        .{},
    );
    document.deinit();
}

fn metadataAllocationFailureCase(allocator: std.mem.Allocator) !void {
    const config = xml.Configs.XML10_NAMESPACES_VALIDATING_DETAILED;
    const input =
        "<!DOCTYPE r [" ++
        "<!ELEMENT r EMPTY>" ++
        "<!ATTLIST r a CDATA 'v'>" ++
        "<!NOTATION n SYSTEM 'urn:n'>" ++
        "<!ENTITY u SYSTEM 'urn:u' NDATA n>" ++
        "]><r/>";
    var document = try parse(config, allocator, input, .{});
    document.deinit();
}

test "[failure] - [owned tree]: releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureCase,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        metadataAllocationFailureCase,
        .{},
    );
}

test "[failure] - [owned tree]: rejects an inconsistent public event stream" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    var builder = try xml.TreeBuilder(config).init(std.testing.allocator, .{});
    defer builder.deinit();
    try builder.consume(.{ .document_start = .{} });
    try builder.consume(.{ .start_element = .{
        .name = .{ .raw = "open" },
        .attributes = &.{},
        .empty_element_syntax = false,
    } });
    try std.testing.expectError(
        error.InvalidEventSequence,
        builder.consume(.{ .end_element = .{ .name = .{ .raw = "other" } } }),
    );
}

test "[failure] - [owned tree]: rejects interrupted fragments and remains failed" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    var builder = try xml.TreeBuilder(config).init(std.testing.allocator, .{});
    defer builder.deinit();
    try builder.consume(.{ .document_start = .{} });
    try builder.consume(.{ .comment = .{ .bytes = "part", .complete = false } });
    try std.testing.expectError(
        error.InvalidEventSequence,
        builder.consume(.{ .start_element = .{
            .name = .{ .raw = "r" },
            .attributes = &.{},
            .empty_element_syntax = true,
        } }),
    );
    try std.testing.expectError(
        error.InvalidEventSequence,
        builder.consume(.{ .comment = .{ .bytes = "rest", .complete = true } }),
    );
    try std.testing.expectError(error.InvalidEventSequence, builder.finish());
}

test "[failure] - [owned tree]: transfers document storage only once" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    var builder = try xml.TreeBuilder(config).init(std.testing.allocator, .{});
    defer builder.deinit();
    try builder.consume(.{ .document_start = .{} });
    try builder.consume(.{ .start_element = .{
        .name = .{ .raw = "r" },
        .attributes = &.{},
        .empty_element_syntax = true,
    } });
    try builder.consume(.{ .end_element = .{ .name = .{ .raw = "r" } } });
    try builder.consume(.{ .document_end = .{} });
    var document = try builder.finish();
    defer document.deinit();

    try std.testing.expectError(error.InvalidEventSequence, builder.finish());
}

test "[failure] - [owned tree]: rejects a second document element" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    var builder = try xml.TreeBuilder(config).init(std.testing.allocator, .{});
    defer builder.deinit();
    try builder.consume(.{ .document_start = .{} });
    try builder.consume(.{ .start_element = .{
        .name = .{ .raw = "first" },
        .attributes = &.{},
        .empty_element_syntax = true,
    } });
    try builder.consume(.{ .end_element = .{ .name = .{ .raw = "first" } } });

    try std.testing.expectError(
        error.InvalidEventSequence,
        builder.consume(.{ .start_element = .{
            .name = .{ .raw = "second" },
            .attributes = &.{},
            .empty_element_syntax = true,
        } }),
    );
}

test "[property] - [owned tree]: retains a large shallow document with bounded indices" {
    const element_count = 10_000;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.ensureTotalCapacity(std.testing.allocator, element_count * 4 + 7);
    try input.appendSlice(std.testing.allocator, "<r>");
    for (0..element_count) |_| try input.appendSlice(std.testing.allocator, "<x/>");
    try input.appendSlice(std.testing.allocator, "</r>");

    var document = try parse(
        xml.Configs.XML10_UTF8_NO_DTD_FAST,
        std.testing.allocator,
        input.items,
        .{},
    );
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, element_count + 2), document.memoryUsage().node_count);
    var children = document.children(document.documentElement());
    var observed: usize = 0;
    while (children.next()) |_| observed += 1;
    try std.testing.expectEqual(@as(usize, element_count), observed);
    try std.testing.expect(document.memoryUsage().total_capacity_bytes < element_count * 64);
}

const Summary = struct {
    elements: usize = 0,
    attributes: usize = 0,
    text_bytes: usize = 0,
    comments: usize = 0,
    processing_instructions: usize = 0,
};

fn eventSummary(comptime config: xml.Config, input: []const u8) !Summary {
    var pull = try xml.SliceReader(config).init(std.testing.allocator, .{}, input);
    defer pull.deinit();
    var result: Summary = .{};
    while (true) switch (try pull.next()) {
        .event => |event| switch (event) {
            .start_element => |value| {
                result.elements += 1;
                result.attributes += value.attributes.len;
            },
            .text => |value| result.text_bytes += value.bytes.len,
            .comment => |value| if (value.complete) {
                result.comments += 1;
            },
            .processing_instruction => |value| if (value.complete) {
                result.processing_instructions += 1;
            },
            else => {},
        },
        .need_input => unreachable,
        .done => return result,
    };
}

fn treeSummary(document: anytype) Summary {
    var result: Summary = .{};
    var index: xml.NodeIndex = 1;
    while (index <= document.memoryUsage().node_count) : (index += 1) {
        switch (document.nodeKind(index).?) {
            .document => {},
            .element => {
                result.elements += 1;
                result.attributes += document.attributeCount(index);
            },
            .text => result.text_bytes += document.nodeValue(index).?.len,
            .comment => result.comments += 1,
            .processing_instruction => result.processing_instructions += 1,
        }
    }
    return result;
}

test "[property] - [owned tree]: traversal summary matches the public event stream" {
    const config = xml.Configs.XML10_UTF8_NO_DTD;
    const cases = [_][]const u8{
        "<r/>",
        "<!--a--><r a='1'><x/>text&amp;more<?p value?></r><!--b-->",
        "<r>one<![CDATA[two]]>three</r>",
    };
    for (cases) |input| {
        const expected = try eventSummary(config, input);
        var document = try parse(config, std.testing.allocator, input, .{});
        defer document.deinit();
        try std.testing.expectEqual(expected, treeSummary(&document));
    }
}
