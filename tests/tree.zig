//! Verifies the public immutable owned-tree contract.

const std = @import("std");
const xml = @import("z_xml");

fn parse(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    input: []const u8,
    tree_options: xml.ProfileTreeOptions,
) !xml.ProfileDocumentFor(config) {
    return parseWithReaderOptions(config, allocator, .{}, input, tree_options);
}

fn parseWithReaderOptions(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    reader_options: xml.OptionsFor(config),
    input: []const u8,
    tree_options: xml.ProfileTreeOptions,
) !xml.ProfileDocumentFor(config) {
    var pull = try xml.ProfileSliceReader(config).init(allocator, reader_options, input);
    defer pull.deinit();
    return xml.buildProfileTreeFromPull(config, allocator, tree_options, &pull);
}

fn parseTemporaryDocument(allocator: std.mem.Allocator) !xml.Document {
    var input =
        ("<?xml version='1.0' standalone='yes'?>" ++
            "<!--before--><?target data?>" ++
            "<!DOCTYPE p:r [<!ELEMENT p:r (#PCDATA)><!ATTLIST p:r a CDATA #REQUIRED>]>" ++
            "<p:r xmlns:p='urn:test' a='value'>text</p:r>").*;
    const document = try xml.parseDocument(allocator, .{ .slice = &input }, .{});
    @memset(&input, 0);
    return document;
}

fn parseDocumentWithExternalFinding(allocator: std.mem.Allocator) !xml.Document {
    var subset = try xml.ExternalSubset.compileDecoded(
        allocator,
        "schema.dtd",
        "<!ELEMENT r EMPTY><!ELEMENT r EMPTY>",
        .{ .source_id = 90 },
    );
    defer subset.deinit();
    return xml.parseDocument(
        allocator,
        .{ .slice = "<!DOCTYPE r SYSTEM 'schema.dtd'><r/>" },
        .{ .reader = .{ .dtd = .{ .validate = .{ .external_subset = &subset } } } },
    );
}

test "[integration] - [document]: owns retained XML after the source expires" {
    var document = try parseTemporaryDocument(std.testing.allocator);
    defer document.deinit();

    const invalid = std.math.maxInt(xml.Node);
    try std.testing.expectEqual(@as(?xml.NodeKind, null), document.nodeKind(0));
    try std.testing.expectEqual(@as(?xml.NodeKind, null), document.nodeKind(invalid));
    try std.testing.expectEqual(@as(xml.Node, 0), document.parent(document.root()));
    try std.testing.expectEqual(@as(xml.Node, 0), document.parent(invalid));
    try std.testing.expectEqual(@as(?xml.Name, null), document.nodeName(invalid));
    try std.testing.expectEqual(@as(?[]const u8, null), document.nodeValue(invalid));
    try std.testing.expectEqual(@as(?xml.TextOrigin, null), document.textOrigin(invalid));
    try std.testing.expect(document.processingInstruction(invalid) == null);
    try std.testing.expectEqual(@as(?xml.Attribute, null), document.attribute(invalid, null, "a"));
    try std.testing.expectEqual(@as(?xml.Attribute, null), document.attributeRaw(invalid, "a"));
    var invalid_attributes = document.attributes(invalid);
    try std.testing.expectEqual(@as(?xml.Attribute, null), invalid_attributes.next());
    var invalid_declarations = document.namespaceDeclarations(invalid);
    try std.testing.expectEqual(
        @as(?xml.DocumentNamespaceDeclaration, null),
        invalid_declarations.next(),
    );
    var invalid_children = document.children(invalid);
    try std.testing.expectEqual(@as(?xml.Node, null), invalid_children.next());

    const start = document.documentStart();
    try std.testing.expectEqual(xml.XmlVersion.xml10, start.effective_version);
    try std.testing.expectEqual(xml.XmlVersion.xml10, start.declaration.?.version);
    try std.testing.expectEqual(@as(?[]const u8, null), start.declaration.?.encoding);
    try std.testing.expectEqual(true, start.declaration.?.standalone.?);
    try std.testing.expectEqualStrings("p:r", document.documentType().?.root_name);

    const element = document.documentElement();
    const name = document.nodeName(element).?;
    try std.testing.expectEqualStrings("p:r", name.raw);
    try std.testing.expectEqualStrings("urn:test", name.expanded.?.namespace_uri.?);
    try std.testing.expectEqualStrings("value", document.attribute(element, null, "a").?.value);
    var attributes = document.attributes(element);
    try std.testing.expectEqualStrings("a", attributes.next().?.name.raw);
    try std.testing.expectEqual(@as(?xml.Attribute, null), attributes.next());

    var document_children = document.children(document.root());
    const comment = document_children.next().?;
    try std.testing.expectEqualStrings("before", document.nodeValue(comment).?);
    const instruction = document.processingInstruction(document_children.next().?).?;
    try std.testing.expectEqualStrings("target", instruction.target);
    try std.testing.expectEqualStrings("data", instruction.data);
    try std.testing.expectEqual(element, document_children.next().?);

    var declarations = document.namespaceDeclarations(element);
    const declaration = declarations.next().?;
    try std.testing.expectEqualStrings("p", declaration.prefix.?);
    try std.testing.expectEqualStrings("urn:test", declaration.namespace_uri);
    try std.testing.expectEqual(@as(?xml.DocumentNamespaceDeclaration, null), declarations.next());

    var children = document.children(element);
    const text = children.next().?;
    try std.testing.expectEqualStrings("text", document.nodeValue(text).?);
    try std.testing.expectEqual(@as(?xml.TextOrigin, null), document.textOrigin(text));
    try std.testing.expectEqual(@as(?xml.Node, null), children.next());
    try std.testing.expectEqual(xml.DocumentContent.complete, document.documentEnd().content);
    try std.testing.expect(document.memoryUsage().total_capacity_bytes > 0);
}

test "[integration] - [document]: joins fragments from caller-owned stream input" {
    const input = "<r>ab<!--cd--><?p ef?></r>";
    var input_buffer: [1]u8 = undefined;
    var source: std.testing.Reader = .init(&input_buffer, &.{.{ .buffer = input }});
    source.artificial_limit = .limited(1);
    var document = try xml.parseDocument(
        std.testing.allocator,
        .{ .stream = &source.interface },
        .{ .reader = .{ .limits = .{ .max_fragment_bytes = 1 } } },
    );
    defer document.deinit();

    var children = document.children(document.documentElement());
    try std.testing.expectEqualStrings("ab", document.nodeValue(children.next().?).?);
    try std.testing.expectEqualStrings("cd", document.nodeValue(children.next().?).?);
    const instruction = document.processingInstruction(children.next().?).?;
    try std.testing.expectEqualStrings("p", instruction.target);
    try std.testing.expectEqualStrings("ef", instruction.data);
    try std.testing.expectEqual(@as(?xml.Node, null), children.next());
}

test "[integration] - [document]: keeps skipped external content as a text boundary" {
    const input = "<!DOCTYPE r [<!ENTITY ext SYSTEM 'external.ent'>]><r>a&ext;b</r>";
    var document = try xml.parseDocument(std.testing.allocator, .{ .slice = input }, .{
        .reader = .{ .external = .skip },
    });
    defer document.deinit();

    var children = document.children(document.documentElement());
    try std.testing.expectEqualStrings("a", document.nodeValue(children.next().?).?);
    try std.testing.expectEqualStrings("b", document.nodeValue(children.next().?).?);
    try std.testing.expectEqual(@as(?xml.Node, null), children.next());
    try std.testing.expectEqual(
        xml.DocumentContent.external_content_skipped,
        document.documentEnd().content,
    );
}

test "[integration] - [document]: applies retention and raw-name options without changing type" {
    const input = "<r xmlns='urn:test' a='value'>a<!--comment-->b<?target data?><![CDATA[c]]></r>";
    var compact = try xml.parseDocument(std.testing.allocator, .{ .slice = input }, .{
        .reader = .{ .namespaces = .raw, .dtd = .reject },
        .retain_comments = false,
        .retain_processing_instructions = false,
    });
    defer compact.deinit();

    const element = compact.documentElement();
    try std.testing.expectEqual(@as(?xml.ExpandedName, null), compact.nodeName(element).?.expanded);
    try std.testing.expectEqualStrings(
        "urn:test",
        compact.attributeRaw(element, "xmlns").?.value,
    );
    try std.testing.expectEqualStrings("value", compact.attributeRaw(element, "a").?.value);
    var declarations = compact.namespaceDeclarations(element);
    try std.testing.expectEqual(@as(?xml.DocumentNamespaceDeclaration, null), declarations.next());
    var children = compact.children(element);
    const text = children.next().?;
    try std.testing.expectEqualStrings("abc", compact.nodeValue(text).?);
    try std.testing.expectEqual(@as(?xml.Node, null), children.next());
    try std.testing.expectEqual(@as(?xml.Attribute, null), compact.attribute(element, null, "a"));

    var origins = try xml.parseDocument(
        std.testing.allocator,
        .{ .slice = "<r>a<![CDATA[b]]></r>" },
        .{ .retain_text_origin = true },
    );
    defer origins.deinit();
    var origin_children = origins.children(origins.documentElement());
    try std.testing.expectEqual(
        xml.TextOrigin.character_data,
        origins.textOrigin(origin_children.next().?).?,
    );
    try std.testing.expectEqual(xml.TextOrigin.cdata, origins.textOrigin(origin_children.next().?).?);
}

test "[integration] - [document]: retains validation and normalization findings" {
    const input =
        "<!DOCTYPE r [<!ELEMENT r EMPTY>" ++
        "<!ATTLIST r required CDATA #REQUIRED mode (a|b) 'a'>]>" ++
        "<r/>";
    var document = try xml.parseDocument(std.testing.allocator, .{ .slice = input }, .{
        .reader = .{ .dtd = .{ .validate = .{} } },
    });
    defer document.deinit();

    try std.testing.expectEqual(xml.DtdValidity.invalid, document.documentEnd().dtd_validity);
    try std.testing.expectEqual(
        xml.DiagnosticCode.validity_required_attribute,
        document.firstDtdFinding().?.code,
    );
    const defaulted = document.attribute(document.documentElement(), null, "mode").?;
    try std.testing.expectEqualStrings("a", defaulted.value);
    try std.testing.expect(!defaulted.specified);
    try std.testing.expectEqual(xml.AttributeType.enumeration, defaulted.declared_type.?);

    var external_finding = try parseDocumentWithExternalFinding(std.testing.allocator);
    defer external_finding.deinit();
    const retained_finding = external_finding.firstDtdFinding().?;
    try std.testing.expectEqual(
        xml.DiagnosticCode.validity_duplicate_element_declaration,
        retained_finding.code,
    );
    try std.testing.expectEqual(@as(u32, 90), retained_finding.primary.source_id);
    try std.testing.expectEqual(@as(usize, 1), retained_finding.inclusion_trace.len);
    try std.testing.expectEqual(@as(u32, 0), retained_finding.inclusion_trace[0].source_id);

    var normalization = try xml.parseDocument(
        std.testing.allocator,
        .{ .slice = "<?xml version='1.1'?><r>e\xcc\x81</r>" },
        .{},
    );
    defer normalization.deinit();
    try std.testing.expectEqual(
        xml.DocumentNormalization.not_normalized,
        normalization.documentEnd().normalization,
    );
    try std.testing.expectEqual(
        xml.NormalizationIssueKind.not_nfc,
        normalization.normalizationFinding().?.kind,
    );
}

test "[failure] - [document]: reports option, XML, and document limit errors" {
    try std.testing.expectError(
        error.InvalidOptions,
        xml.parseDocument(std.testing.allocator, .{ .slice = "<r/>" }, .{
            .limits = .{ .max_nodes = 0 },
        }),
    );
    try std.testing.expectError(
        error.InvalidXml,
        xml.parseDocument(std.testing.allocator, .{ .slice = "<r>" }, .{}),
    );
    try std.testing.expectError(
        error.DocumentLimit,
        xml.parseDocument(std.testing.allocator, .{ .slice = "<r/>" }, .{
            .limits = .{ .max_nodes = 1 },
        }),
    );
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
    try std.testing.expectEqual(@as(?xml.Node, null), children.next());

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
    var reader_options: xml.OptionsFor(config) = .{};
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
    const expected = [_]xml.ProfileTreeDtdRecordKind{
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
    try std.testing.expectEqual(xml.ProfileTreeDtdRecordKind.entity_start, document.dtdRecordAt(5).?.kind);
    try std.testing.expectEqual(xml.ProfileTreeDtdRecordKind.entity_end, document.dtdRecordAt(6).?.kind);
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
    try std.testing.expectEqual(xml.ProfileTreeDtdRecordKind.skipped_entity, skipped.kind);
    try std.testing.expectEqual(xml.ProfileSkippedEntityKind.general_entity, skipped.skipped_entity_kind.?);
}

test "[integration] - [owned tree]: retains validating whitespace classification" {
    const config: xml.Config = .{ .profile = .xml10_dtd_validating };
    const input = "<!DOCTYPE r [<!ELEMENT r (x)><!ELEMENT x EMPTY>]><r> \n<x/></r>";
    var document = try parse(config, std.testing.allocator, input, .{});
    defer document.deinit();

    const text = document.firstChild(document.documentElement());
    try std.testing.expect(document.isIgnorableWhitespace(text));
    try std.testing.expectEqual(xml.ProfileValidationStatus.valid, document.validationStatus().?);
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
    try std.testing.expectEqual(@as(xml.Node, 0), merged.nextSibling(text));

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
        xml.ProfileTreeBuilderFor(config).init(std.testing.allocator, .{
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
    var builder = try xml.ProfileTreeBuilderFor(config).init(std.testing.allocator, .{});
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
    var builder = try xml.ProfileTreeBuilderFor(config).init(std.testing.allocator, .{});
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
    var builder = try xml.ProfileTreeBuilderFor(config).init(std.testing.allocator, .{});
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
    var builder = try xml.ProfileTreeBuilderFor(config).init(std.testing.allocator, .{});
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
    var pull = try xml.ProfileSliceReader(config).init(std.testing.allocator, .{}, input);
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
    var index: xml.Node = 1;
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
