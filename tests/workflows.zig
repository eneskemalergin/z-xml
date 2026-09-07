//! Public XML workflows shared by package tests and a clean dependent package.
//!
//! Selection, indexes, checksums, and source copying are caller work. These tests
//! combine Reader, Writer, and owned Document operations without private imports.
//! Literal bytes and values complement round trips. Caller buffers and temporary
//! files remain separate from XML allocations, including on partial failure.

const std = @import("std");
const xml = @import("z_xml");

const INPUT = "<?xml version='1.1'?>" ++
    "<catalog xmlns='urn:catalog' xmlns:p='urn:payload'>" ++
    "<record id='drop'><p:data>ignored&amp;text</p:data></record>" ++
    "<record id='keep' label='A&#x9;B'><p:data>A&amp;<![CDATA[<]]>" ++
    "\xc3\xa9\xf0\x9f\x99\x82e\xcc\x81\r\nZ</p:data></record></catalog>";
const VALUE = "A&<\xc3\xa9\xf0\x9f\x99\x82e\xcc\x81\nZ";
const OUTPUT = "<?xml version=\"1.1\" encoding=\"UTF-8\"?>" ++
    "<catalog xmlns=\"urn:catalog\" xmlns:p=\"urn:payload\">" ++
    "<record id=\"keep\" label=\"A&#x9;B\"><p:data>A&amp;&lt;" ++
    "\xc3\xa9\xf0\x9f\x99\x82e\xcc\x81\nZ</p:data></record></catalog>";

const Selection = struct {
    skipped: ?xml.SourceSpan = null,
    selected: ?xml.SourceSpan = null,
    label: ?xml.SourceSpan = null,
    text_bytes: usize = 0,
    final_fragments: usize = 0,
};

fn rewrite(allocator: std.mem.Allocator, source: xml.Source, sink: *std.Io.Writer, options: xml.ReaderOptions) !Selection {
    var reader = try xml.Reader.init(allocator, source, options);
    defer reader.deinit();
    const first = (try reader.next()).?;
    try std.testing.expectEqual(.document_start, std.meta.activeTag(first.data));
    var writer = try xml.Writer.init(allocator, sink, .{ .version = first.data.document_start.effective_version });
    defer writer.deinit();
    try writer.startDocument();
    var result: Selection = .{};
    var complete = false;
    while (try reader.next()) |event| {
        switch (event.data) {
            .start_element => |start| {
                if (start.name.eql("urn:catalog", "record")) {
                    const id = start.attribute(null, "id").?;
                    if (std.mem.eql(u8, id.value, "drop")) {
                        result.skipped = try reader.skipElement();
                        continue;
                    }
                    try std.testing.expectEqualStrings("keep", id.value);
                    result.selected = event.span;
                    const label = start.attribute(null, "label").?;
                    try std.testing.expectEqualStrings("A\tB", label.value);
                    result.label = label.span;
                }
                try writer.startElement(start.name.raw);
                for (start.namespace_declarations) |declaration| try writer.namespace(declaration.prefix, declaration.namespace_uri);
                for (start.attributes) |attribute| try writer.attribute(attribute.name.raw, attribute.value);
            },
            .end_element => try writer.endElement(),
            .text => |value| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(value.bytes));
                try writer.text(value.bytes);
                result.text_bytes += value.bytes.len;
                result.final_fragments += @intFromBool(value.final_fragment);
            },
            .document_end => |end| {
                try std.testing.expectEqual(.complete, end.content);
                try writer.endDocument();
                complete = true;
            },
            else => return error.UnexpectedEvent,
        }
    }
    try std.testing.expect(complete);
    try std.testing.expectEqual(null, try reader.next());
    return result;
}

fn expectMetadata(document: *const xml.Document) !void {
    const catalog = document.documentElement();
    try std.testing.expect(document.nodeName(catalog).?.eql("urn:catalog", "catalog"));
    var records = document.children(catalog);
    const record = records.next().?;
    try std.testing.expectEqual(null, records.next());
    try std.testing.expectEqualStrings("keep", document.attribute(record, null, "id").?.value);
    try std.testing.expectEqualStrings("A\tB", document.attribute(record, null, "label").?.value);
    var children = document.children(record);
    const data = children.next().?;
    try std.testing.expectEqual(null, children.next());
    try std.testing.expect(document.nodeName(data).?.eql("urn:payload", "data"));
    var text = document.children(data);
    try std.testing.expectEqualStrings(VALUE, document.nodeValue(text.next().?).?);
    try std.testing.expectEqual(null, text.next());
    try std.testing.expectEqual(.complete, document.documentEnd().content);
}

fn selectedMetadata(allocator: std.mem.Allocator, source: xml.Source, options: xml.ReaderOptions) !Selection {
    var bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    const result = try rewrite(allocator, source, &output, options);
    try std.testing.expectEqualStrings(OUTPUT, output.buffered());
    try std.testing.expectEqual(VALUE.len, result.text_bytes);
    try std.testing.expectEqual(@as(usize, 1), result.final_fragments);
    var document = try xml.parseDocument(allocator, .{ .slice = output.buffered() }, .{});
    defer document.deinit();
    @memset(&bytes, 0);
    try expectMetadata(&document);
    return result;
}

fn pairTranscode(_: ?*anyopaque, input: []const u8, final: bool, output: []u8, advances: []u8) xml.TranscodeStep {
    if (input.len < 2) return if (final and input.len != 0) .{ .malformed = 0 } else .need_input;
    if (input[0] != 0) return .{ .malformed = 0 };
    if (output.len == 0) return .need_output;
    output[0] = input[1];
    advances[0] = 2;
    return .{ .progress = .{ .consumed = 2, .produced = 1 } };
}

fn selectionAllocationFailure(allocator: std.mem.Allocator) !void {
    _ = try selectedMetadata(allocator, .{ .slice = INPUT }, .{});
}

const IndexedSink = struct {
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = &.{} },
    bytes: [512]u8 = undefined,
    len: usize = 0,
    hash: std.hash.Crc32 = .init(),
    hash_until: usize = std.math.maxInt(usize),
    fail_at: usize = std.math.maxInt(usize),
    max_write: usize = 7,
    flushes: usize = 0,
    fail_flush: bool = false,

    fn accept(self: *IndexedSink, bytes: []const u8) std.Io.Writer.Error!usize {
        if (self.len == self.fail_at) return error.WriteFailed;
        const count = @min(bytes.len, self.max_write, self.fail_at - self.len);
        const hashed = @min(count, self.hash_until -| self.len);
        self.hash.update(bytes[0..hashed]);
        @memcpy(self.bytes[self.len..][0..count], bytes[0..count]);
        self.len += count;
        return count;
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *IndexedSink = @alignCast(@fieldParentPtr("interface", writer));
        if (writer.end != 0) {
            const count = try self.accept(writer.buffered());
            std.mem.copyForwards(u8, writer.buffer[0 .. writer.end - count], writer.buffer[count..writer.end]);
            writer.end -= count;
            return 0;
        }
        for (data, 0..) |bytes, index| {
            if (index == data.len - 1 and splat == 0) break;
            if (bytes.len != 0) return self.accept(bytes);
        }
        return 0;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *IndexedSink = @alignCast(@fieldParentPtr("interface", writer));
        self.flushes += 1;
        if (self.fail_flush) return error.WriteFailed;
        while (writer.end != 0) _ = try drain(writer, &.{""}, 1);
    }
};

const INDEXED_OUTPUT = "<catalog><record id=\"one\">A&amp;B</record><index offset=\"9\"/></catalog>";

fn writeIndexed(writer: *xml.Writer, sink: *IndexedSink) !void {
    try writer.startDocument();
    try writer.startElement("catalog");
    try writer.startElement("record");
    const offset = writer.byteOffset().?;
    var id = "one".*;
    try writer.attribute("id", &id);
    @memset(&id, 'x');
    try writer.text("A&B");
    try writer.endElement();
    try writer.startElement("index");
    sink.hash_until = @intCast(writer.byteOffset().?);
    var digits: [20]u8 = undefined;
    try writer.attribute("offset", try std.fmt.bufPrint(&digits, "{d}", .{offset}));
    try writer.endElement();
    try writer.endElement();
    try writer.endDocument();
}

test "[integration] - [indexed output]: matches physical offsets checksum prefixes and flush failures" {
    const boundary = std.mem.indexOf(u8, INDEXED_OUTPUT, "<index").?;
    for ([_]usize{ 0, 17, 256 }) |buffer_size| {
        var buffer: [256]u8 = undefined;
        var sink: IndexedSink = .{};
        sink.interface.buffer = buffer[0..buffer_size];
        var writer = try xml.Writer.init(std.testing.allocator, &sink.interface, .{ .emit_declaration = false });
        defer writer.deinit();
        try writeIndexed(&writer, &sink);
        try std.testing.expectEqual(@as(?u64, INDEXED_OUTPUT.len), writer.byteOffset());
        try std.testing.expectEqual(@as(usize, 0), sink.flushes);
        try std.testing.expectEqual(boundary, sink.hash_until);
        sink.fail_flush = true;
        const accepted = sink.len;
        try std.testing.expectError(error.WriteFailed, sink.interface.flush());
        try std.testing.expectEqual(accepted, sink.len);
        try std.testing.expectEqual(@as(?u64, INDEXED_OUTPUT.len), writer.byteOffset());
        sink.fail_flush = false;
        try sink.interface.flush();
        try std.testing.expectEqualStrings(INDEXED_OUTPUT, sink.bytes[0..sink.len]);
        try std.testing.expectEqual(std.hash.Crc32.hash(INDEXED_OUTPUT[0..boundary]), sink.hash.final());

        var reader = try xml.Reader.init(std.testing.allocator, .{ .slice = sink.bytes[0..sink.len] }, .{});
        defer reader.deinit();
        var record_offset: ?u64 = null;
        var matched_index = false;
        var completed = false;
        var text_bytes: usize = 0;
        var text_finals: usize = 0;
        while (try reader.next()) |event| switch (event.data) {
            .start_element => |start| {
                if (start.name.eql(null, "record")) record_offset = event.span.start;
                if (start.name.eql(null, "index")) {
                    const indexed = try std.fmt.parseInt(u64, start.attribute(null, "offset").?.value, 10);
                    try std.testing.expectEqual(record_offset.?, indexed);
                    try std.testing.expectEqual(@as(u64, 9), indexed);
                    matched_index = true;
                }
            },
            .text => |text| {
                try std.testing.expectEqualStrings("A&B"[text_bytes .. text_bytes + text.bytes.len], text.bytes);
                text_bytes += text.bytes.len;
                text_finals += @intFromBool(text.final_fragment);
            },
            .document_end => completed = true,
            else => {},
        };
        try std.testing.expect(matched_index and completed);
        try std.testing.expectEqual(@as(usize, 3), text_bytes);
        try std.testing.expectEqual(@as(usize, 1), text_finals);
    }
    for (0..INDEXED_OUTPUT.len) |failure_offset| for ([_]usize{ 0, 256 }) |buffer_size| {
        var buffer: [256]u8 = undefined;
        var sink: IndexedSink = .{ .fail_at = failure_offset, .max_write = 1 };
        sink.interface.buffer = buffer[0..buffer_size];
        var writer = try xml.Writer.init(std.testing.allocator, &sink.interface, .{ .emit_declaration = false });
        defer writer.deinit();
        if (buffer_size == 0) {
            try std.testing.expectError(error.WriteFailed, writeIndexed(&writer, &sink));
            try std.testing.expectEqual(null, writer.byteOffset());
            try std.testing.expectError(error.WriteFailed, writer.endDocument());
        } else {
            try writeIndexed(&writer, &sink);
            try std.testing.expectEqual(@as(usize, 0), sink.len);
            try std.testing.expectError(error.WriteFailed, sink.interface.flush());
            try std.testing.expectEqual(@as(?u64, INDEXED_OUTPUT.len), writer.byteOffset());
            try std.testing.expectEqualStrings(INDEXED_OUTPUT[failure_offset..], sink.interface.buffered());
        }
        try std.testing.expectEqualStrings(INDEXED_OUTPUT[0..failure_offset], sink.bytes[0..sink.len]);
        try std.testing.expectEqual(std.hash.Crc32.hash(INDEXED_OUTPUT[0..@min(failure_offset, boundary)]), sink.hash.final());
        try std.testing.expectEqual(failure_offset, sink.len);
        if (buffer_size != 0) {
            sink.fail_at = std.math.maxInt(usize);
            try sink.interface.flush();
            try std.testing.expectEqualStrings(INDEXED_OUTPUT, sink.bytes[0..sink.len]);
            try std.testing.expectEqual(std.hash.Crc32.hash(INDEXED_OUTPUT[0..boundary]), sink.hash.final());
            try std.testing.expectEqual(@as(usize, 0), sink.interface.buffered().len);
        }
    };
}

test "[integration] - [source transform]: replaces one checked span and preserves surrounding bytes" {
    const original = "<?xml version='1.0'?>\n<root a = 'raw'><!--keep--><item value='old'/><tail /></root>\n";
    var reader = try xml.Reader.init(std.testing.allocator, .{ .slice = original }, .{});
    defer reader.deinit();
    var replacement: ?xml.SourceSpan = null;
    var completed = false;
    while (try reader.next()) |event| switch (event.data) {
        .start_element => |start| if (start.name.eql(null, "item")) {
            replacement = try reader.skipElement();
        },
        .document_end => completed = true,
        else => {},
    };
    try std.testing.expect(completed);
    const span = replacement.?;
    try std.testing.expectEqual(@as(u32, 0), span.source_id);
    try std.testing.expectEqualStrings("<item value='old'/>", original[@intCast(span.start)..@intCast(span.end)]);
    var rebuilt: [128]u8 = undefined;
    var rebuilt_output = std.Io.Writer.fixed(&rebuilt);
    var writer = try xml.Writer.init(std.testing.allocator, &rebuilt_output, .{ .emit_declaration = false });
    defer writer.deinit();
    try writer.startDocument();
    try writer.startElement("item");
    try writer.attribute("value", "new&value");
    try writer.endElement();
    try writer.endDocument();
    var bytes: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    try output.writeAll(original[0..@intCast(span.start)]);
    try output.writeAll(rebuilt_output.buffered());
    try output.writeAll(original[@intCast(span.end)..]);
    try std.testing.expectEqualStrings("<?xml version='1.0'?>\n<root a = 'raw'><!--keep--><item value=\"new&amp;value\"/><tail /></root>\n", output.buffered());
    var document = try xml.parseDocument(std.testing.allocator, .{ .slice = output.buffered() }, .{});
    defer document.deinit();
    var children = document.children(document.documentElement());
    try std.testing.expectEqual(.comment, document.nodeKind(children.next().?).?);
    try std.testing.expectEqualStrings("new&value", document.attribute(children.next().?, null, "value").?.value);
}

test "[integration] - [validation workflow]: reuses a compiled grammar and retains owned findings" {
    var declarations = ("<!ELEMENT records (item*)><!ELEMENT item EMPTY>" ++
        "<!ATTLIST item id ID #REQUIRED kind CDATA 'default'>").*;
    var subset = try xml.dtd.ExternalSubset.compileDecoded(std.testing.allocator, "records.dtd", &declarations, .{});
    defer subset.deinit();
    @memset(&declarations, 0);
    const options: xml.ReaderOptions = .{ .dtd = .{ .validate = .{ .external_subset = &subset } } };
    const valid = "<!DOCTYPE records SYSTEM 'records.dtd'><records><item id='one'/></records>";
    const invalid = "<!DOCTYPE records SYSTEM 'records.dtd'><records><item id='one'/><item id='one'/></records>";
    var reader = try xml.Reader.init(std.testing.allocator, .{ .slice = valid }, options);
    defer reader.deinit();
    for ([_][]const u8{ valid, invalid, valid }) |input| {
        try reader.reset(.{ .slice = input }, options, .retain_capacity);
        var result: ?xml.DtdValidity = null;
        while (try reader.next()) |event| switch (event.data) {
            .start_element => |start| if (start.name.eql(null, "item")) {
                const attribute = start.attribute(null, "kind").?;
                try std.testing.expectEqualStrings("default", attribute.value);
                try std.testing.expect(!attribute.specified and attribute.span == null);
            },
            .document_end => |end| result = end.dtd_validity,
            else => {},
        };
        const is_invalid = std.mem.eql(u8, input, invalid);
        try std.testing.expectEqual(@as(?xml.DtdValidity, if (is_invalid) .invalid else .valid), result);
        if (is_invalid) try std.testing.expectEqual(.validity_duplicate_id, reader.firstDtdFinding().?.code);
    }
    var document = try xml.parseDocument(std.testing.allocator, .{ .slice = invalid }, .{ .reader = options });
    defer document.deinit();
    try std.testing.expectEqual(.invalid, document.documentEnd().dtd_validity);
    try std.testing.expectEqual(.validity_duplicate_id, document.firstDtdFinding().?.code);
    var normalized = try xml.parseDocument(std.testing.allocator, .{ .slice = "<?xml version='1.1'?><r>e\xcc\x81</r>" }, .{});
    defer normalized.deinit();
    try std.testing.expectEqual(.not_normalized, normalized.documentEnd().normalization);
    try std.testing.expectEqual(.not_nfc, normalized.normalizationFinding().?.kind);
}

test "[integration] - [external workflow]: closes abandoned sources and copies Document diagnostics" {
    const Provider = struct {
        bytes: []const u8 = "<piece>value</piece>",
        cursor: usize = 0,
        closes: usize = 0,
        reports: usize = 0,
        code: ?xml.DiagnosticCode = null,
        primary: ?xml.Location = null,
        inclusion: ?xml.Location = null,

        fn resolve(context: ?*anyopaque, request: xml.ResolverRequest) xml.ResolverResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, request.system_id, "piece.xml")) return .not_found;
            self.cursor = 0;
            return .{ .source = .{ .context = context, .source_id = 17, .readFn = read, .closeFn = close } };
        }

        fn read(context: ?*anyopaque, output: []u8) xml.ResolverReadResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.cursor == self.bytes.len) return .end;
            const count = @min(output.len, 2, self.bytes.len - self.cursor);
            @memcpy(output[0..count], self.bytes[self.cursor..][0..count]);
            self.cursor += count;
            return .{ .bytes = count };
        }

        fn close(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closes += 1;
        }

        fn report(context: ?*anyopaque, diagnostic: xml.Diagnostic) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.reports += 1;
            self.code = diagnostic.code;
            self.primary = diagnostic.primary;
            if (diagnostic.inclusion_trace.len == 1) self.inclusion = diagnostic.inclusion_trace[0];
        }
    };
    const root = "<!DOCTYPE r [<!ENTITY piece SYSTEM 'piece.xml'>]><r>&piece;</r>";
    var provider: Provider = .{};
    const options: xml.ReaderOptions = .{
        .external = .resolve,
        .resolver = .{ .context = &provider, .resolveFn = Provider.resolve },
        .diagnostic_sink = .{ .context = &provider, .report_fn = Provider.report },
    };
    var reader = try xml.Reader.init(std.testing.allocator, .{ .slice = root }, options);
    defer reader.deinit();
    while (try reader.next()) |event| {
        if (event.span.source_id == 17 and event.data == .start_element) break;
    } else return error.MissingExternalElement;
    try std.testing.expectEqual(@as(usize, 0), provider.closes);
    try reader.reset(.{ .slice = "<ok/>" }, .{}, .release_memory);
    try std.testing.expectEqual(@as(usize, 1), provider.closes);
    while (try reader.next()) |_| {}

    provider.bytes = "<piece>value</wrong>";
    try std.testing.expectError(error.InvalidXml, xml.parseDocument(std.testing.allocator, .{ .slice = root }, .{ .reader = options }));
    try std.testing.expectEqual(@as(usize, 2), provider.closes);
    try std.testing.expectEqual(@as(usize, 1), provider.reports);
    try std.testing.expectEqual(.mismatched_end_tag, provider.code.?);
    try std.testing.expectEqual(@as(u32, 17), provider.primary.?.source_id);
    try std.testing.expectEqual(@as(u64, 14), provider.primary.?.byte_offset);
    try std.testing.expectEqual(@as(u32, 0), provider.inclusion.?.source_id);
    try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, root, "&piece;").?), provider.inclusion.?.byte_offset);
}

test "[integration] - [metadata workflow]: selects inherited names and owns rewritten values" {
    for ([_]usize{ 0, 1, 7, 31 }) |chunk_size| {
        var buffer: [31]u8 = undefined;
        var source: std.testing.Reader = .init(buffer[0..chunk_size], &.{.{ .buffer = INPUT }});
        source.artificial_limit = .limited(chunk_size);
        const result = try selectedMetadata(std.testing.allocator, if (chunk_size == 0)
            .{ .slice = INPUT }
        else
            .{ .stream = &source.interface }, .{ .limits = .{ .max_fragment_bytes = 7 } });
        const skip_start = std.mem.indexOf(u8, INPUT, "<record id='drop'>").?;
        const keep_start = std.mem.indexOf(u8, INPUT, "<record id='keep'").?;
        try std.testing.expectEqual(xml.SourceSpan{ .source_id = 0, .start = skip_start, .end = keep_start }, result.skipped.?);
        try std.testing.expectEqual(@as(u64, keep_start), result.selected.?.start);
        try std.testing.expectEqualStrings("label='A&#x9;B'", INPUT[@intCast(result.label.?.start)..@intCast(result.label.?.end)]);
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, selectionAllocationFailure, .{});
}

test "[integration] - [metadata workflow]: selects from UTF-16 and caller-transcoded sources" {
    const words = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, INPUT);
    defer std.testing.allocator.free(words);
    for ([_]enum { little, big, pairs }{ .little, .big, .pairs }) |encoding| {
        const size = if (encoding == .pairs) INPUT.len * 2 else words.len * 2 + 2;
        const bytes = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(bytes);
        var options: xml.ReaderOptions = .{ .limits = .{ .max_fragment_bytes = 7 } };
        if (encoding == .pairs) {
            for (INPUT, 0..) |byte, index| {
                bytes[2 * index] = 0;
                bytes[2 * index + 1] = byte;
            }
            options.transcoder = .{ .context = null, .runFn = pairTranscode };
        } else {
            const endian: std.builtin.Endian = if (encoding == .little) .little else .big;
            std.mem.writeInt(u16, bytes[0..2], 0xfeff, endian);
            for (words, 0..) |word, index| std.mem.writeInt(u16, bytes[2 + 2 * index ..][0..2], word, endian);
        }
        for ([_]usize{ 0, 1, 7 }) |chunk_size| {
            var buffer: [7]u8 = undefined;
            var source: std.testing.Reader = .init(buffer[0..chunk_size], &.{.{ .buffer = bytes }});
            source.artificial_limit = .limited(chunk_size);
            const result = try selectedMetadata(std.testing.allocator, if (chunk_size == 0)
                .{ .slice = bytes }
            else
                .{ .stream = &source.interface }, options);
            const start = std.mem.indexOf(u8, INPUT, "<record id='keep'").?;
            try std.testing.expectEqual(@as(u64, start * 2 + (if (encoding == .pairs) @as(usize, 0) else 2)), result.selected.?.start);
            try std.testing.expectEqual(@as(u32, 0), result.selected.?.source_id);
        }
    }
}

test "[integration] - [selection reuse]: distinguishes early stop from checked failure and reset" {
    const input = "<catalog xmlns='urn:catalog'><record id='keep'/><record id='drop'><bad></record></catalog>";
    var reader = try xml.Reader.init(std.testing.allocator, .{ .slice = input }, .{});
    defer reader.deinit();
    for ([_]xml.ResetMode{ .retain_capacity, .release_memory }) |mode| {
        while (try reader.next()) |event| {
            if (event.data == .start_element and event.data.start_element.name.eql("urn:catalog", "record")) break;
        } else return error.MissingSelection;
        try std.testing.expectEqual(null, reader.diagnostic());
        try reader.reset(.{ .slice = input }, .{}, mode);
        while (try reader.next()) |event| {
            if (event.data == .start_element and event.data.start_element.name.eql("urn:catalog", "record")) {
                const id = event.data.start_element.attribute(null, "id").?;
                if (std.mem.eql(u8, id.value, "drop")) break;
                _ = try reader.skipElement();
            }
        } else return error.MissingSelection;
        try std.testing.expectError(error.InvalidXml, reader.skipElement());
        const diagnostic = reader.diagnostic().?;
        try std.testing.expectEqual(.mismatched_end_tag, diagnostic.code);
        try std.testing.expectEqual(@as(u64, std.mem.indexOf(u8, input, "</record>").? + 2), diagnostic.primary.byte_offset);
        try std.testing.expectError(error.InvalidXml, reader.next());
        try reader.reset(.{ .slice = "<ok/>" }, .{}, mode);
        var completed = false;
        while (try reader.next()) |event| if (event.data == .document_end) {
            completed = true;
        };
        try std.testing.expect(completed);
        try std.testing.expectEqual(null, reader.diagnostic());
        try reader.reset(.{ .slice = input }, .{}, mode);
    }
}

test "[integration] - [payload workflow]: rewrites large fragmented text with bounded XML storage" {
    const pattern = "QUJDRA==";
    const total = 3 * 1024 * 1024;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_file = try temporary.dir.createFile(std.testing.io, "source.xml", .{ .read = true });
    defer source_file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var source_output = source_file.writer(std.testing.io, &buffer);
    try source_output.interface.writeAll("<payload>");
    var chunk: [4096]u8 = undefined;
    for (&chunk, 0..) |*byte, index| byte.* = pattern[index % pattern.len];
    for (0..total / chunk.len) |_| try source_output.interface.writeAll(&chunk);
    try source_output.interface.writeAll("</payload>");
    try source_output.interface.flush();

    const output_file = try temporary.dir.createFile(std.testing.io, "output.xml", .{ .read = true });
    defer output_file.close(std.testing.io);
    var output_buffer: [4096]u8 = undefined;
    var output = output_file.writer(std.testing.io, &output_buffer);
    var input_buffer: [127]u8 = undefined;
    var input = source_file.reader(std.testing.io, &input_buffer);
    var xml_storage: [128 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&xml_storage);
    const result = try rewrite(allocator.allocator(), .{ .stream = &input.interface }, &output.interface, .{
        .limits = .{ .max_fragment_bytes = 257 },
    });
    try std.testing.expectEqual(@as(usize, total), result.text_bytes);
    try std.testing.expectEqual(@as(usize, 1), result.final_fragments);
    try output.interface.flush();

    var verify_buffer: [113]u8 = undefined;
    var verify_input = output_file.reader(std.testing.io, &verify_buffer);
    var reader_storage: [64 * 1024]u8 = undefined;
    var reader_allocator = std.heap.FixedBufferAllocator.init(&reader_storage);
    var reader = try xml.Reader.init(reader_allocator.allocator(), .{ .stream = &verify_input.interface }, .{});
    defer reader.deinit();
    var count: usize = 0;
    var finals: usize = 0;
    var completed = false;
    while (try reader.next()) |event| switch (event.data) {
        .text => |text| {
            for (text.bytes) |byte| {
                try std.testing.expectEqual(pattern[count % pattern.len], byte);
                count += 1;
            }
            finals += @intFromBool(text.final_fragment);
        },
        .document_end => completed = true,
        else => {},
    };
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(usize, total), count);
    try std.testing.expectEqual(@as(usize, 1), finals);
    try std.testing.expect(reader.memoryUsage().retained_capacity < reader_storage.len);
    try reader.reset(.{ .slice = "<small/>" }, .{}, .release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
    for (0..16) |_| {
        var ends: usize = 0;
        while (try reader.next()) |event| if (event.data == .document_end) {
            ends += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), ends);
        try reader.reset(.{ .slice = "<small/>" }, .{}, .retain_capacity);
    }
}

test "[integration] - [workflow failures]: preserves source errors limits and encoding failures" {
    for ([_]struct { input: []const u8, failure: xml.ReadError, code: xml.DiagnosticCode }{
        .{ .input = "<r>\xff</r>", .failure = error.InvalidEncoding, .code = .malformed_utf8 },
        .{ .input = "\xfe\xff\x00<\x00r\x00/\x00>\x00", .failure = error.InvalidEncoding, .code = .malformed_encoding },
        .{ .input = "<r>&#x1;</r>", .failure = error.InvalidXml, .code = .invalid_character_reference },
    }) |case| {
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = case.input }});
        source.artificial_limit = .limited(1);
        var reader = try xml.Reader.init(std.testing.allocator, .{ .stream = &source.interface }, .{});
        defer reader.deinit();
        while (reader.next()) |event| {
            if (event == null) return error.ExpectedFailure;
        } else |err| try std.testing.expectEqual(case.failure, err);
        try std.testing.expectEqual(case.code, reader.diagnostic().?.code);
        try std.testing.expectError(case.failure, reader.next());
    }
    const BrokenSource = struct {
        fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var interrupted = std.Io.Reader.fixed("<catalog><item/>");
    interrupted.vtable = &.{ .stream = BrokenSource.stream };
    for ([_]struct { source: xml.Source, failure: xml.ReadError, written: []const u8 }{
        .{ .source = .{ .stream = &interrupted }, .failure = error.ReadFailed, .written = "<catalog>" },
        .{ .source = .{ .slice = "<catalog><item/></wrong>" }, .failure = error.InvalidXml, .written = "<catalog><item/>" },
    }) |case| {
        var output: IndexedSink = .{};
        try std.testing.expectError(case.failure, rewrite(std.testing.allocator, case.source, &output.interface, .{}));
        const declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
        try std.testing.expectEqualStrings(declaration, output.bytes[0..declaration.len]);
        try std.testing.expectEqualStrings(case.written, output.bytes[declaration.len..output.len]);
        try std.testing.expectEqual(@as(usize, 0), output.flushes);
    }
    var broken = std.Io.Reader.fixed("<catalog>");
    broken.vtable = &.{ .stream = BrokenSource.stream };
    var reader = try xml.Reader.init(std.testing.allocator, .{ .stream = &broken }, .{});
    defer reader.deinit();
    while (reader.next()) |event| {
        if (event == null) return error.ExpectedFailure;
    } else |err| try std.testing.expectEqual(error.ReadFailed, err);
    try std.testing.expectEqual(.read_failed, reader.diagnostic().?.code);
    try std.testing.expectEqual(@as(u64, 9), reader.diagnostic().?.primary.byte_offset);
    try std.testing.expectError(error.ReadFailed, reader.next());

    try reader.reset(.{ .slice = INPUT }, .{ .limits = .{ .max_depth = 2 } }, .retain_capacity);
    while (reader.next()) |event| {
        if (event == null) return error.ExpectedFailure;
    } else |err| try std.testing.expectEqual(error.LimitExceeded, err);
    try std.testing.expectEqual(.depth_limit, reader.diagnostic().?.code);
    try std.testing.expectError(error.LimitExceeded, reader.next());
    try std.testing.expectError(error.DocumentLimit, xml.parseDocument(std.testing.allocator, .{ .slice = OUTPUT }, .{
        .limits = .{ .max_nodes = 2 },
    }));
}
