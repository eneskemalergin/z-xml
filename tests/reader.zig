//! Public contract tests for the streaming reader.

const std = @import("std");
const xml = @import("z_xml");

const CORE_CONFIG = xml.Configs.XML10_UTF8_NO_DTD;
const FAST_CONFIG = xml.Configs.XML10_UTF8_NO_DTD_FAST;
const NS_CONFIG = xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD;
const GENERAL_CONFIG = xml.Configs.XML10_NO_DTD;
const GENERAL_FAST_CONFIG = xml.Configs.XML10_NO_DTD_FAST;
const DTD_CONFIG = xml.Configs.XML10_NONVALIDATING;
const DTD_NS_CONFIG = xml.Configs.XML10_NAMESPACES_NONVALIDATING;
const INTERNAL_DTD_CONFIG = xml.Configs.XML10_NONVALIDATING_INTERNAL;
const CoreReader = xml.ReaderFor(CORE_CONFIG);

const UTF16LE_BOM = @embedFile("data/encoding/utf16le-bom.xml");
const UTF16BE_BOM = @embedFile("data/encoding/utf16be-bom.xml");
const UTF16LE_ODD_BYTE = @embedFile("data/encoding/utf16le-odd-byte.xml");
const UTF16LE_UNPAIRED_HIGH = @embedFile(
    "data/encoding/utf16le-unpaired-high-surrogate.xml",
);
const UTF16BE_UNPAIRED_LOW = @embedFile(
    "data/encoding/utf16be-unpaired-low-surrogate.xml",
);

const NAMESPACE_CHURN_INPUT =
    "<r:root xmlns:r=\"urn:root\" xmlns:a=\"urn:outer-a\" " ++
    "xmlns:b=\"urn:outer-b\" xmlns=\"urn:default\">\n" ++
    "  <a:item a:kind=\"one\">\n" ++
    "    <inner xmlns:a=\"urn:inner-a\" xmlns=\"urn:inner-default\">\n" ++
    "      <a:item b:kind=\"two\"/>\n" ++
    "    </inner>\n" ++
    "  </a:item>\n" ++
    "  <b:item xmlns:b=\"urn:inner-b\" b:kind=\"three\"/>\n" ++
    "  <plain xmlns=\"\"><leaf xmlns=\"urn:leaf\"/></plain>\n" ++
    "</r:root>\n";

const Summary = struct {
    const max_attribute_event_bytes = 4096;
    const max_name_event_bytes = 4096;
    const max_text_bytes = 4096;
    const max_summary_bytes = 4096;
    const start_element_marker = 0xfe;
    const name_end_marker = 0;
    const attribute_end_marker = 0xff;

    sequence: u64 = 0,
    source_encoding: xml.SourceEncoding = .utf8,
    declared_version: [32]u8 = @splat(0),
    declared_version_len: usize = 0,
    declared_encoding: [32]u8 = @splat(0),
    declared_encoding_len: usize = 0,
    standalone: bool = false,
    standalone_declared: bool = false,
    starts: usize = 0,
    ends: usize = 0,
    empty_starts: usize = 0,
    name_bytes: usize = 0,
    attributes: usize = 0,
    attribute_name_bytes: usize = 0,
    attribute_value_bytes: usize = 0,
    attribute_event_bytes: [max_attribute_event_bytes]u8 = @splat(0),
    attribute_event_bytes_len: usize = 0,
    text_bytes: [max_text_bytes]u8 = @splat(0),
    text_bytes_len: usize = 0,
    cdata_bytes: [max_summary_bytes]u8 = @splat(0),
    cdata_bytes_len: usize = 0,
    complete_comments: usize = 0,
    comment_bytes: [max_summary_bytes]u8 = @splat(0),
    comment_bytes_len: usize = 0,
    complete_processing_instructions: usize = 0,
    processing_instruction_active: bool = false,
    processing_instruction_bytes: [max_summary_bytes]u8 = @splat(0),
    processing_instruction_bytes_len: usize = 0,
    name_event_bytes: [max_name_event_bytes]u8 = @splat(0),
    name_event_bytes_len: usize = 0,
    namespace_declarations: usize = 0,
    namespace_event_bytes: [max_summary_bytes]u8 = @splat(0),
    namespace_event_bytes_len: usize = 0,

    fn observe(self: *Summary, event: anytype) !void {
        switch (event) {
            .document_start => |document| {
                self.sequence *%= 10;
                self.sequence +%= 1;
                self.source_encoding = document.source_encoding;
                if (document.declared_version) |version| {
                    if (version.len > self.declared_version.len) {
                        return error.DeclaredVersionSummaryTooLarge;
                    }
                    @memcpy(self.declared_version[0..version.len], version);
                    self.declared_version_len = version.len;
                }
                if (document.declared_encoding) |encoding| {
                    if (encoding.len > self.declared_encoding.len) {
                        return error.DeclaredEncodingSummaryTooLarge;
                    }
                    @memcpy(self.declared_encoding[0..encoding.len], encoding);
                    self.declared_encoding_len = encoding.len;
                }
                self.standalone = document.standalone;
                self.standalone_declared = document.standalone_declared;
            },
            .start_element => |start| {
                self.sequence *%= 10;
                self.sequence +%= 2;
                self.starts += 1;
                self.empty_starts += @intFromBool(start.empty_element_syntax);
                self.name_bytes += start.name.raw.len;
                self.attributes += start.attributes.len;
                try self.appendNameEventBytes("S");
                try self.appendNameEventBytes(start.name.raw);
                try self.appendNameEventBytes("\x00");
                if (@hasField(@TypeOf(start.name), "namespace_uri")) {
                    try self.appendExpandedName(start.name);
                    for (start.namespace_declarations) |declaration| {
                        self.namespace_declarations += 1;
                        try self.appendNamespaceEventBytes(declaration.prefix orelse "");
                        try self.appendNamespaceEventBytes("\x00");
                        try self.appendNamespaceEventBytes(declaration.namespace_uri);
                        try self.appendNamespaceEventBytes("\xff");
                    }
                }
                try self.appendAttributeEventBytes(&.{start_element_marker});
                for (start.attributes) |attribute| {
                    self.attribute_name_bytes += attribute.name.raw.len;
                    self.attribute_value_bytes += attribute.value.len;
                    try self.appendAttributeEventBytes(attribute.name.raw);
                    try self.appendAttributeEventBytes(&.{name_end_marker});
                    try self.appendAttributeEventBytes(attribute.value);
                    try self.appendAttributeEventBytes(&.{attribute_end_marker});
                    if (@hasField(@TypeOf(attribute.name), "namespace_uri")) {
                        try self.appendExpandedName(attribute.name);
                    }
                }
            },
            .end_element => |end| {
                self.sequence *%= 10;
                self.sequence +%= 3;
                self.ends += 1;
                self.name_bytes += end.name.raw.len;
                try self.appendNameEventBytes("E");
                try self.appendNameEventBytes(end.name.raw);
                try self.appendNameEventBytes("\x00");
                if (@hasField(@TypeOf(end.name), "namespace_uri")) {
                    try self.appendExpandedName(end.name);
                }
            },
            .text => |text| {
                try self.appendText(text.bytes);
                if (text.origin == .cdata) try self.appendCdataBytes(text.bytes);
            },
            .comment => |comment| {
                self.complete_comments += @intFromBool(comment.complete);
                try self.appendCommentBytes(comment.bytes);
            },
            .processing_instruction => |instruction| {
                if (!self.processing_instruction_active) {
                    try self.appendProcessingInstructionBytes(instruction.target);
                    try self.appendProcessingInstructionBytes("\x00");
                    self.processing_instruction_active = true;
                }
                self.complete_processing_instructions += @intFromBool(instruction.complete);
                try self.appendProcessingInstructionBytes(instruction.data);
                if (instruction.complete) {
                    try self.appendProcessingInstructionBytes("\xff");
                    self.processing_instruction_active = false;
                }
            },
            else => {
                if (std.mem.eql(u8, @tagName(std.meta.activeTag(event)), "document_end")) {
                    self.sequence *%= 10;
                    self.sequence +%= 4;
                }
            },
        }
    }

    fn appendAttributeEventBytes(self: *Summary, bytes: []const u8) !void {
        const end = std.math.add(usize, self.attribute_event_bytes_len, bytes.len) catch
            return error.AttributeEventSummaryTooLarge;
        if (end > self.attribute_event_bytes.len) return error.AttributeEventSummaryTooLarge;
        @memcpy(self.attribute_event_bytes[self.attribute_event_bytes_len..end], bytes);
        self.attribute_event_bytes_len = end;
    }

    fn appendText(self: *Summary, bytes: []const u8) !void {
        const end = std.math.add(usize, self.text_bytes_len, bytes.len) catch
            return error.TextSummaryTooLarge;
        if (end > self.text_bytes.len) return error.TextSummaryTooLarge;
        @memcpy(self.text_bytes[self.text_bytes_len..end], bytes);
        self.text_bytes_len = end;
    }

    fn appendNameEventBytes(self: *Summary, bytes: []const u8) !void {
        const end = std.math.add(usize, self.name_event_bytes_len, bytes.len) catch
            return error.NameEventSummaryTooLarge;
        if (end > self.name_event_bytes.len) return error.NameEventSummaryTooLarge;
        @memcpy(self.name_event_bytes[self.name_event_bytes_len..end], bytes);
        self.name_event_bytes_len = end;
    }

    fn appendNamespaceEventBytes(self: *Summary, bytes: []const u8) !void {
        const end = std.math.add(usize, self.namespace_event_bytes_len, bytes.len) catch
            return error.NamespaceEventSummaryTooLarge;
        if (end > self.namespace_event_bytes.len) return error.NamespaceEventSummaryTooLarge;
        @memcpy(self.namespace_event_bytes[self.namespace_event_bytes_len..end], bytes);
        self.namespace_event_bytes_len = end;
    }

    fn appendExpandedName(self: *Summary, name: anytype) !void {
        try self.appendNamespaceEventBytes(name.raw);
        try self.appendNamespaceEventBytes("\x00");
        try self.appendNamespaceEventBytes(name.prefix orelse "");
        try self.appendNamespaceEventBytes("\x00");
        try self.appendNamespaceEventBytes(name.local);
        try self.appendNamespaceEventBytes("\x00");
        try self.appendNamespaceEventBytes(name.namespace_uri orelse "");
        try self.appendNamespaceEventBytes("\xff");
    }

    fn appendCommentBytes(self: *Summary, bytes: []const u8) !void {
        const end = std.math.add(usize, self.comment_bytes_len, bytes.len) catch
            return error.CommentSummaryTooLarge;
        if (end > self.comment_bytes.len) return error.CommentSummaryTooLarge;
        @memcpy(self.comment_bytes[self.comment_bytes_len..end], bytes);
        self.comment_bytes_len = end;
    }

    fn appendCdataBytes(self: *Summary, bytes: []const u8) !void {
        const end = std.math.add(usize, self.cdata_bytes_len, bytes.len) catch
            return error.CdataSummaryTooLarge;
        if (end > self.cdata_bytes.len) return error.CdataSummaryTooLarge;
        @memcpy(self.cdata_bytes[self.cdata_bytes_len..end], bytes);
        self.cdata_bytes_len = end;
    }

    fn appendProcessingInstructionBytes(self: *Summary, bytes: []const u8) !void {
        const end = std.math.add(
            usize,
            self.processing_instruction_bytes_len,
            bytes.len,
        ) catch return error.ProcessingInstructionSummaryTooLarge;
        if (end > self.processing_instruction_bytes.len) {
            return error.ProcessingInstructionSummaryTooLarge;
        }
        @memcpy(
            self.processing_instruction_bytes[self.processing_instruction_bytes_len..end],
            bytes,
        );
        self.processing_instruction_bytes_len = end;
    }
};

const ExpectedAttribute = struct {
    name: []const u8,
    value: []const u8,
};

const ExpectedEvent = union(enum) {
    document_start,
    start_element: struct {
        name: []const u8,
        attributes: []const ExpectedAttribute = &.{},
        empty_element_syntax: bool,
    },
    end_element: []const u8,
    text: []const u8,
    document_end,
};

const PushContext = struct {
    events: usize = 0,
    attributes: usize = 0,
    cancel_after: ?usize = null,
};

fn pushObserve(context: *PushContext, event: xml.EventFor(CORE_CONFIG)) xml.ProfileDrainControl {
    context.events += 1;
    switch (event) {
        .start_element => |start| context.attributes += start.attributes.len,
        else => {},
    }
    if (context.cancel_after == context.events) return .cancel;
    return .continue_parsing;
}

fn parseParts(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    options: xml.OptionsFor(config),
    parts: []const []const u8,
) !Summary {
    const Reader = xml.ReaderFor(config);
    var reader = try Reader.init(allocator, options);
    defer reader.deinit();

    var summary: Summary = .{};
    for (parts, 0..) |part, index| {
        try reader.feed(part, index + 1 == parts.len);
        while (true) {
            switch (try reader.next()) {
                .event => |event| try summary.observe(event),
                .need_input => break,
                .done => return summary,
            }
        }
    }
    return error.MissingDone;
}

fn parseOneByteChunks(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    options: xml.OptionsFor(config),
    input: []const u8,
) !Summary {
    const Reader = xml.ReaderFor(config);
    var reader = try Reader.init(allocator, options);
    defer reader.deinit();

    var summary: Summary = .{};
    for (input, 0..) |_, index| {
        try reader.feed(input[index .. index + 1], index + 1 == input.len);
        while (true) {
            switch (try reader.next()) {
                .event => |event| try summary.observe(event),
                .need_input => break,
                .done => return summary,
            }
        }
    }
    return error.MissingDone;
}

fn parseFixedChunks(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    options: xml.OptionsFor(config),
    input: []const u8,
    chunk_size: usize,
) !Summary {
    const Reader = xml.ReaderFor(config);
    var reader = try Reader.init(allocator, options);
    defer reader.deinit();

    var summary: Summary = .{};
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + chunk_size, input.len);
        try reader.feed(input[offset..end], end == input.len);
        offset = end;
        while (true) {
            switch (try reader.next()) {
                .event => |event| try summary.observe(event),
                .need_input => break,
                .done => return summary,
            }
        }
    }
    return error.MissingDone;
}

fn parseRandomChunks(
    comptime config: xml.Config,
    allocator: std.mem.Allocator,
    options: xml.OptionsFor(config),
    input: []const u8,
    seed: u64,
) !Summary {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const Reader = xml.ReaderFor(config);
    var reader = try Reader.init(allocator, options);
    defer reader.deinit();

    var summary: Summary = .{};
    var offset: usize = 0;
    while (offset < input.len) {
        const max_chunk = @min(@as(usize, 7), input.len - offset);
        const chunk_size = random.intRangeAtMost(usize, 1, max_chunk);
        const end = offset + chunk_size;
        try reader.feed(input[offset..end], end == input.len);
        offset = end;
        while (true) {
            switch (try reader.next()) {
                .event => |event| try summary.observe(event),
                .need_input => break,
                .done => return summary,
            }
        }
    }
    return error.MissingDone;
}

fn expectSummarySchedules(input: []const u8, expected: Summary) !void {
    return expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, input, expected);
}

fn expectSummarySchedulesWithOptions(
    comptime config: xml.Config,
    options: xml.OptionsFor(config),
    input: []const u8,
    expected: Summary,
) !void {
    const whole_parts = [_][]const u8{input};
    const whole = try parseParts(config, std.testing.allocator, options, &whole_parts);
    try expectSummaryMetrics(expected, whole);
    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try std.testing.expectEqual(
            whole,
            try parseParts(config, std.testing.allocator, options, &parts),
        );
    }
    try std.testing.expectEqual(
        whole,
        try parseOneByteChunks(config, std.testing.allocator, options, input),
    );
    inline for (.{ 2, 3, 5, 7, 11 }) |chunk_size| {
        try std.testing.expectEqual(
            whole,
            try parseFixedChunks(config, std.testing.allocator, options, input, chunk_size),
        );
    }
    for (0..16) |seed| {
        try std.testing.expectEqual(
            whole,
            try parseRandomChunks(config, std.testing.allocator, options, input, seed),
        );
    }
}

fn expectSummaryMetrics(expected: Summary, actual: Summary) !void {
    try std.testing.expectEqual(expected.sequence, actual.sequence);
    try std.testing.expectEqual(expected.source_encoding, actual.source_encoding);
    try std.testing.expectEqualStrings(
        expected.declared_version[0..expected.declared_version_len],
        actual.declared_version[0..actual.declared_version_len],
    );
    try std.testing.expectEqualStrings(
        expected.declared_encoding[0..expected.declared_encoding_len],
        actual.declared_encoding[0..actual.declared_encoding_len],
    );
    try std.testing.expectEqual(expected.standalone, actual.standalone);
    try std.testing.expectEqual(expected.standalone_declared, actual.standalone_declared);
    try std.testing.expectEqual(expected.starts, actual.starts);
    try std.testing.expectEqual(expected.ends, actual.ends);
    try std.testing.expectEqual(expected.empty_starts, actual.empty_starts);
    try std.testing.expectEqual(expected.name_bytes, actual.name_bytes);
    try std.testing.expectEqual(expected.attributes, actual.attributes);
    try std.testing.expectEqual(expected.attribute_name_bytes, actual.attribute_name_bytes);
    try std.testing.expectEqual(expected.attribute_value_bytes, actual.attribute_value_bytes);
    try std.testing.expectEqual(expected.namespace_declarations, actual.namespace_declarations);
    try std.testing.expectEqualStrings(
        expected.namespace_event_bytes[0..expected.namespace_event_bytes_len],
        actual.namespace_event_bytes[0..actual.namespace_event_bytes_len],
    );
    try std.testing.expectEqualStrings(
        expected.text_bytes[0..expected.text_bytes_len],
        actual.text_bytes[0..actual.text_bytes_len],
    );
    try std.testing.expectEqualStrings(
        expected.cdata_bytes[0..expected.cdata_bytes_len],
        actual.cdata_bytes[0..actual.cdata_bytes_len],
    );
    try std.testing.expectEqual(expected.complete_comments, actual.complete_comments);
    try std.testing.expectEqualStrings(
        expected.comment_bytes[0..expected.comment_bytes_len],
        actual.comment_bytes[0..actual.comment_bytes_len],
    );
    try std.testing.expectEqual(
        expected.complete_processing_instructions,
        actual.complete_processing_instructions,
    );
    try std.testing.expectEqualStrings(
        expected.processing_instruction_bytes[0..expected.processing_instruction_bytes_len],
        actual.processing_instruction_bytes[0..actual.processing_instruction_bytes_len],
    );
}

fn expectSemanticSchedules(
    input: []const u8,
    text: []const u8,
    starts: usize,
    ends: usize,
    attributes: usize,
) !void {
    const parts = [_][]const u8{input};
    const whole = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqual(starts, whole.starts);
    try std.testing.expectEqual(ends, whole.ends);
    try std.testing.expectEqual(attributes, whole.attributes);
    try std.testing.expectEqualStrings(text, whole.text_bytes[0..whole.text_bytes_len]);
    try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, input, whole);
}

const TestEndian = enum { little, big };

fn encodeUtf16(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    endian: TestEndian,
    include_signature: bool,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (include_signature) {
        try output.appendSlice(
            allocator,
            if (endian == .little) "\xff\xfe" else "\xfe\xff",
        );
    }
    var iterator = (try std.unicode.Utf8View.init(utf8)).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x10000) {
            try appendUtf16Unit(&output, allocator, @intCast(codepoint), endian);
        } else {
            const value = @as(u32, codepoint) - 0x10000;
            try appendUtf16Unit(
                &output,
                allocator,
                @intCast(0xd800 + (value >> 10)),
                endian,
            );
            try appendUtf16Unit(
                &output,
                allocator,
                @intCast(0xdc00 + (value & 0x3ff)),
                endian,
            );
        }
    }
    return output.toOwnedSlice(allocator);
}

fn appendUtf16Unit(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    unit: u16,
    endian: TestEndian,
) !void {
    const low: u8 = @truncate(unit);
    const high: u8 = @truncate(unit >> 8);
    if (endian == .little) {
        try output.appendSlice(allocator, &.{ low, high });
    } else {
        try output.appendSlice(allocator, &.{ high, low });
    }
}

fn allocationUtf16Parse(allocator: std.mem.Allocator) !void {
    const parts = [_][]const u8{UTF16LE_BOM};
    _ = try parseParts(GENERAL_CONFIG, allocator, .{}, &parts);
}

fn drainGeneralChunks(reader: *xml.ReaderFor(GENERAL_FAST_CONFIG), input: []const u8) !void {
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + 257, input.len);
        try reader.feed(input[offset..end], end == input.len);
        offset = end;
        while (true) switch (try reader.next()) {
            .event => {},
            .need_input => break,
            .done => return,
        };
    }
    return error.MissingDone;
}

fn expectEvents(input: []const u8, expected: []const ExpectedEvent) !void {
    const SliceReader = xml.ProfileSliceReader(CORE_CONFIG);
    var reader = try SliceReader.init(std.testing.allocator, .{}, input);
    defer reader.deinit();

    var index: usize = 0;
    while (true) {
        switch (try reader.next()) {
            .event => |event| {
                if (index == expected.len) return error.UnexpectedEvent;
                switch (event) {
                    .document_start => switch (expected[index]) {
                        .document_start => {},
                        else => return error.UnexpectedEvent,
                    },
                    .start_element => |start| switch (expected[index]) {
                        .start_element => |wanted| {
                            try std.testing.expectEqualStrings(wanted.name, start.name.raw);
                            try std.testing.expectEqual(
                                wanted.empty_element_syntax,
                                start.empty_element_syntax,
                            );
                            try std.testing.expectEqual(wanted.attributes.len, start.attributes.len);
                            for (wanted.attributes, start.attributes) |wanted_attribute, attribute| {
                                try std.testing.expectEqualStrings(
                                    wanted_attribute.name,
                                    attribute.name.raw,
                                );
                                try std.testing.expectEqualStrings(
                                    wanted_attribute.value,
                                    attribute.value,
                                );
                            }
                        },
                        else => return error.UnexpectedEvent,
                    },
                    .end_element => |end| switch (expected[index]) {
                        .end_element => |wanted| {
                            try std.testing.expectEqualStrings(wanted, end.name.raw);
                        },
                        else => return error.UnexpectedEvent,
                    },
                    .text => |text| switch (expected[index]) {
                        .text => |wanted| try std.testing.expectEqualStrings(wanted, text.bytes),
                        else => return error.UnexpectedEvent,
                    },
                    .document_end => switch (expected[index]) {
                        .document_end => {},
                        else => return error.UnexpectedEvent,
                    },
                    else => return error.UnexpectedEvent,
                }
                index += 1;
            },
            .need_input => return error.UnexpectedNeedInput,
            .done => {
                try std.testing.expectEqual(expected.len, index);
                return;
            },
        }
    }
}

fn expectCoreFailure(
    options: xml.OptionsFor(FAST_CONFIG),
    input: []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    const parts = [_][]const u8{input};
    try expectCoreFailureParts(
        options,
        &parts,
        expected_error,
        code,
        offset,
        related_offset,
    );
}

fn expectCoreFailureParts(
    options: xml.OptionsFor(FAST_CONFIG),
    parts: []const []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    const Reader = xml.ReaderFor(FAST_CONFIG);
    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();

    for (parts, 0..) |part, part_index| {
        try reader.feed(part, part_index + 1 == parts.len);
        while (true) {
            const step = reader.next() catch |actual_error| {
                try std.testing.expectEqual(expected_error, actual_error);
                const diagnostic = reader.diagnostic().?;
                try std.testing.expectEqual(code, diagnostic.code);
                try std.testing.expectEqual(offset, diagnostic.primary.byte_offset);
                if (related_offset) |wanted| {
                    try std.testing.expectEqual(wanted, diagnostic.related.?.byte_offset);
                } else {
                    try std.testing.expect(diagnostic.related == null);
                }
                try std.testing.expectError(expected_error, reader.next());
                return;
            };
            switch (step) {
                .event => {},
                .need_input => break,
                .done => return error.ExpectedFailure,
            }
        }
    }
    return error.ExpectedFailure;
}

fn expectGeneralFailureParts(
    parts: []const []const u8,
    code: xml.DiagnosticCode,
    offset: u64,
) !void {
    const Reader = xml.ReaderFor(GENERAL_FAST_CONFIG);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();

    for (parts, 0..) |part, part_index| {
        try reader.feed(part, part_index + 1 == parts.len);
        while (true) {
            const step = reader.next() catch |actual_error| {
                try std.testing.expectEqual(error.InvalidXml, actual_error);
                const diagnostic = reader.diagnostic().?;
                try std.testing.expectEqual(code, diagnostic.code);
                try std.testing.expectEqual(offset, diagnostic.primary.byte_offset);
                try std.testing.expectError(error.InvalidXml, reader.next());
                return;
            };
            switch (step) {
                .event => {},
                .need_input => break,
                .done => return error.ExpectedFailure,
            }
        }
    }
    return error.ExpectedFailure;
}

fn expectGeneralFailureSchedules(
    input: []const u8,
    code: xml.DiagnosticCode,
    offset: u64,
) !void {
    const whole = [_][]const u8{input};
    try expectGeneralFailureParts(&whole, code, offset);
    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try expectGeneralFailureParts(&parts, code, offset);
    }
}

const FailureChunkSchedule = union(enum) {
    fixed: usize,
    random: u64,
};

fn expectCoreFailureChunked(
    options: xml.OptionsFor(FAST_CONFIG),
    input: []const u8,
    schedule: FailureChunkSchedule,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    diagnostic_offset: u64,
    related_offset: ?u64,
) !void {
    const Reader = xml.ReaderFor(FAST_CONFIG);
    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();

    const seed = switch (schedule) {
        .fixed => 0,
        .random => |value| value,
    };
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var input_offset: usize = 0;
    while (input_offset < input.len) {
        const remaining = input.len - input_offset;
        const chunk_size = switch (schedule) {
            .fixed => |size| @min(size, remaining),
            .random => random.intRangeAtMost(usize, 1, @min(@as(usize, 7), remaining)),
        };
        std.debug.assert(chunk_size > 0);
        const end = input_offset + chunk_size;
        try reader.feed(input[input_offset..end], end == input.len);
        input_offset = end;
        while (true) {
            const step = reader.next() catch |actual_error| {
                try std.testing.expectEqual(expected_error, actual_error);
                const diagnostic = reader.diagnostic().?;
                try std.testing.expectEqual(code, diagnostic.code);
                try std.testing.expectEqual(diagnostic_offset, diagnostic.primary.byte_offset);
                if (related_offset) |wanted| {
                    try std.testing.expectEqual(wanted, diagnostic.related.?.byte_offset);
                } else {
                    try std.testing.expect(diagnostic.related == null);
                }
                try std.testing.expectError(expected_error, reader.next());
                return;
            };
            switch (step) {
                .event => {},
                .need_input => break,
                .done => return error.ExpectedFailure,
            }
        }
    }
    return error.ExpectedFailure;
}

fn expectCoreFailureSchedules(
    input: []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    return expectCoreFailureSchedulesWithOptions(
        .{},
        input,
        expected_error,
        code,
        offset,
        related_offset,
    );
}

fn expectCoreFailureSchedulesWithOptions(
    options: xml.OptionsFor(FAST_CONFIG),
    input: []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    try expectCoreFailure(options, input, expected_error, code, offset, related_offset);
    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try expectCoreFailureParts(
            options,
            &parts,
            expected_error,
            code,
            offset,
            related_offset,
        );
    }
    inline for (.{ 1, 2, 3, 5, 7 }) |chunk_size| {
        try expectCoreFailureChunked(
            options,
            input,
            .{ .fixed = chunk_size },
            expected_error,
            code,
            offset,
            related_offset,
        );
    }
    for (0..8) |seed| {
        try expectCoreFailureChunked(
            options,
            input,
            .{ .random = seed },
            expected_error,
            code,
            offset,
            related_offset,
        );
    }
}

fn expectProfileFailureParts(
    comptime config: xml.Config,
    options: xml.OptionsFor(config),
    parts: []const []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    const Reader = xml.ReaderFor(config);
    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();
    for (parts, 0..) |part, index| {
        try reader.feed(part, index + 1 == parts.len);
        while (true) {
            const step = reader.next() catch |actual_error| {
                try std.testing.expectEqual(expected_error, actual_error);
                const diagnostic = reader.diagnostic().?;
                try std.testing.expectEqual(code, diagnostic.code);
                try std.testing.expectEqual(offset, diagnostic.primary.byte_offset);
                if (related_offset) |related| {
                    try std.testing.expectEqual(related, diagnostic.related.?.byte_offset);
                } else {
                    try std.testing.expect(diagnostic.related == null);
                }
                try std.testing.expectError(expected_error, reader.next());
                return;
            };
            switch (step) {
                .event => {},
                .need_input => break,
                .done => return error.ExpectedFailure,
            }
        }
    }
    return error.ExpectedFailure;
}

fn expectProfileFailureSchedules(
    comptime config: xml.Config,
    options: xml.OptionsFor(config),
    input: []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    const whole = [_][]const u8{input};
    try expectProfileFailureParts(
        config,
        options,
        &whole,
        expected_error,
        code,
        offset,
        related_offset,
    );
    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try expectProfileFailureParts(
            config,
            options,
            &parts,
            expected_error,
            code,
            offset,
            related_offset,
        );
    }
    inline for (.{ 1, 2, 3, 5, 7 }) |chunk_size| {
        var parts: [512][]const u8 = undefined;
        var count: usize = 0;
        var start: usize = 0;
        while (start < input.len) : (count += 1) {
            const end = @min(start + chunk_size, input.len);
            parts[count] = input[start..end];
            start = end;
        }
        try expectProfileFailureParts(
            config,
            options,
            parts[0..count],
            expected_error,
            code,
            offset,
            related_offset,
        );
    }
    for (0..8) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var parts: [512][]const u8 = undefined;
        var count: usize = 0;
        var start: usize = 0;
        while (start < input.len) : (count += 1) {
            const size = random.intRangeAtMost(
                usize,
                1,
                @min(@as(usize, 7), input.len - start),
            );
            parts[count] = input[start .. start + size];
            start += size;
        }
        try expectProfileFailureParts(
            config,
            options,
            parts[0..count],
            expected_error,
            code,
            offset,
            related_offset,
        );
    }
}

fn allocationParse(allocator: std.mem.Allocator) !void {
    const parts = [_][]const u8{
        "<a><b><c><d>",
        "<e><f><g><h><i>",
        "<j><k><l/></k></j>",
        "</i></h></g></f></e></d></c></b></a>",
    };
    var reader = try CoreReader.init(allocator, .{});
    defer reader.deinit();

    var starts: usize = 0;
    var ends: usize = 0;
    for (&parts, 0..) |part, index| {
        try reader.feed(part, index + 1 == parts.len);
        while (true) {
            switch (try reader.next()) {
                .event => |event| switch (event) {
                    .start_element => starts += 1,
                    .end_element => ends += 1,
                    else => {},
                },
                .need_input => break,
                .done => {
                    try std.testing.expectEqual(@as(usize, 12), starts);
                    try std.testing.expectEqual(@as(usize, 12), ends);
                    return;
                },
            }
        }
    }
    return error.MissingDone;
}

const MANY_ATTRIBUTES =
    "<root q='0' p='1' o='2' n='3' m='4' l='5' k='6' j='7' i='8' " ++
    "h='9' g='10' f='11' e='12' d='13' c='14' b='15' a='16'/>";

fn makeAttributeInput(buffer: []u8, count: usize, duplicate_last: bool) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("<root");
    for (0..count) |index| {
        const name_index = if (duplicate_last and index + 1 == count) 0 else index;
        try writer.print(" a{d}='{d}'", .{ name_index, index });
    }
    try writer.writeAll("/>");
    return writer.buffered();
}

fn makeNameDocument(buffer: []u8, codepoint: u21, at_start: bool) ![]const u8 {
    var encoded: [4]u8 = undefined;
    const encoded_len = try std.unicode.utf8Encode(codepoint, &encoded);
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeByte('<');
    if (!at_start) try writer.writeByte('a');
    try writer.writeAll(encoded[0..encoded_len]);
    try writer.writeAll("/>");
    return writer.buffered();
}

fn allocationAttributeParse(allocator: std.mem.Allocator) !void {
    var reader = try CoreReader.init(allocator, .{});
    defer reader.deinit();
    try reader.feed(MANY_ATTRIBUTES, true);

    var summary: Summary = .{};
    while (true) {
        switch (try reader.next()) {
            .event => |event| try summary.observe(event),
            .need_input => return error.UnexpectedNeedInput,
            .done => {
                try std.testing.expectEqual(@as(usize, 17), summary.attributes);
                try std.testing.expectEqual(@as(usize, 17), summary.attribute_name_bytes);
                try std.testing.expectEqual(@as(usize, 24), summary.attribute_value_bytes);
                return;
            },
        }
    }
}

fn allocationTextParse(allocator: std.mem.Allocator) !void {
    const input = "<文書 属性='one&#9;two'>before\r\n🙂&amp;<項目/></文書>";
    const parts = [_][]const u8{input};
    const summary = try parseParts(CORE_CONFIG, allocator, .{}, &parts);
    try std.testing.expectEqual(@as(usize, 2), summary.starts);
    try std.testing.expectEqual(@as(usize, 1), summary.attributes);
    try std.testing.expectEqualStrings(
        "before\n🙂&",
        summary.text_bytes[0..summary.text_bytes_len],
    );
}

fn allocationMarkupParse(allocator: std.mem.Allocator) !void {
    const input =
        "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>" ++
        "<?setup data?><r><!--comment--><![CDATA[<text>&data]]></r><?done?>";
    const parts = [_][]const u8{input};
    const summary = try parseParts(CORE_CONFIG, allocator, .{}, &parts);
    try std.testing.expectEqualStrings(
        "1.0",
        summary.declared_version[0..summary.declared_version_len],
    );
    try std.testing.expectEqual(@as(usize, 1), summary.complete_comments);
    try std.testing.expectEqual(@as(usize, 2), summary.complete_processing_instructions);
    try std.testing.expectEqualStrings(
        "<text>&data",
        summary.cdata_bytes[0..summary.cdata_bytes_len],
    );
}

fn allocationNamespaceParse(allocator: std.mem.Allocator) !void {
    const parts = [_][]const u8{NAMESPACE_CHURN_INPUT};
    const summary = try parseParts(NS_CONFIG, allocator, .{}, &parts);
    try std.testing.expectEqual(@as(usize, 7), summary.starts);
    try std.testing.expectEqual(@as(usize, 7), summary.ends);
    try std.testing.expectEqual(@as(usize, 9), summary.namespace_declarations);
}

fn allocationDtdParse(allocator: std.mem.Allocator) !void {
    const config = xml.Configs.XML10_NAMESPACES_NONVALIDATING;
    const input = "<!DOCTYPE p:root [" ++
        "<!ENTITY % element '<!ELEMENT p:root (#PCDATA)>'>%element;" ++
        "<!ENTITY text 'expanded'><!ATTLIST p:root xmlns:p CDATA 'urn:test' " ++
        "tokens NMTOKENS ' one  two '>]><p:root>&text;</p:root>";
    var reader = try xml.ReaderFor(config).init(allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);
    var starts: usize = 0;
    var text_bytes: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| {
                starts += 1;
                try std.testing.expectEqual(@as(usize, 1), start.attributes.len);
                try std.testing.expectEqual(@as(usize, 1), start.namespace_declarations.len);
            },
            .text => |text| text_bytes += text.bytes.len,
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 1), starts);
    try std.testing.expectEqual(@as(usize, 8), text_bytes);
}

const DtdOutcome = struct {
    doctypes: usize = 0,
    starts: usize = 0,
    ends: usize = 0,
    attributes: usize = 0,
    defaulted: usize = 0,
    namespace_declarations: usize = 0,
    text_hash: u64 = 14695981039346656037,
    validation: ?xml.ProfileValidationStatus = null,
};

const DtdSchedule = union(enum) {
    whole,
    split: usize,
    fixed: usize,
    random: u64,
};

fn dtdOutcome(comptime config: xml.Config, input: []const u8, schedule: DtdSchedule) !DtdOutcome {
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    var outcome: DtdOutcome = .{};
    var offset: usize = 0;
    var first = true;
    var prng = std.Random.DefaultPrng.init(switch (schedule) {
        .random => |seed| seed,
        else => 0,
    });
    while (true) {
        const remaining = input.len - offset;
        const size = switch (schedule) {
            .whole => remaining,
            .split => |value| if (first) value else remaining,
            .fixed => |value| @min(value, remaining),
            .random => prng.random().intRangeAtMost(usize, 1, @min(@as(usize, 17), remaining)),
        };
        first = false;
        const end = offset + size;
        try reader.feed(input[offset..end], end == input.len);
        offset = end;
        while (true) switch (try reader.next()) {
            .event => |event| switch (event) {
                .document_type => outcome.doctypes += 1,
                .start_element => |start| {
                    outcome.starts += 1;
                    outcome.attributes += start.attributes.len;
                    for (start.attributes) |attribute| {
                        outcome.defaulted += @intFromBool(!attribute.specified);
                    }
                    if (@hasField(@TypeOf(start), "namespace_declarations")) {
                        outcome.namespace_declarations += start.namespace_declarations.len;
                    }
                },
                .end_element => outcome.ends += 1,
                .text => |text| for (text.bytes) |byte| {
                    outcome.text_hash ^= byte;
                    outcome.text_hash *%= 1099511628211;
                },
                .document_end => |document_end| {
                    if (@hasField(@TypeOf(document_end), "validation")) {
                        outcome.validation = document_end.validation;
                    }
                },
                else => {},
            },
            .need_input => break,
            .done => return outcome,
        };
        if (offset == input.len) return error.MissingDone;
    }
}

fn normalizationOutcome(
    comptime config: xml.Config,
    options: xml.OptionsFor(config),
    input: []const u8,
    schedule: DtdSchedule,
) !xml.NormalizationResultFor(config) {
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
    defer reader.deinit();
    var offset: usize = 0;
    var first = true;
    var prng = std.Random.DefaultPrng.init(switch (schedule) {
        .random => |seed| seed,
        else => 0,
    });
    while (true) {
        const remaining = input.len - offset;
        const size = switch (schedule) {
            .whole => remaining,
            .split => |value| if (first) value else remaining,
            .fixed => |value| @min(value, remaining),
            .random => prng.random().intRangeAtMost(usize, 1, @min(@as(usize, 17), remaining)),
        };
        first = false;
        const end = offset + size;
        try reader.feed(input[offset..end], end == input.len);
        offset = end;
        while (true) switch (try reader.next()) {
            .event => {},
            .need_input => break,
            .done => return reader.normalizationResult(),
        };
        if (offset == input.len) return error.MissingDone;
    }
}

const NormalizationFailureOutcome = struct {
    events: usize,
    byte_offset: u64,
    line: u64,
    byte_column: u64,
};

fn strictNormalizationFailure(
    input: []const u8,
    chunk_size: usize,
) !NormalizationFailureOutcome {
    const config = xml.Configs.XML11_NONVALIDATING;
    var options: xml.OptionsFor(config) = .{};
    options.normalization = .require;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
    defer reader.deinit();
    var events: usize = 0;
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + chunk_size, input.len);
        try reader.feed(input[offset..end], end == input.len);
        offset = end;
        while (true) {
            const step = reader.next() catch |err| {
                try std.testing.expectEqual(error.NotNormalized, err);
                const diagnostic = reader.diagnostic().?;
                return .{
                    .events = events,
                    .byte_offset = diagnostic.primary.byte_offset,
                    .line = diagnostic.primary.line,
                    .byte_column = diagnostic.primary.byte_column,
                };
            };
            switch (step) {
                .event => events += 1,
                .need_input => break,
                .done => return error.ExpectedFailure,
            }
        }
    }
    return error.ExpectedFailure;
}

fn expectNormalizationSchedules(
    input: []const u8,
    expected: xml.NormalizationResultFor(xml.Configs.XML11_NONVALIDATING),
) !void {
    const config = xml.Configs.XML11_NONVALIDATING;
    try std.testing.expectEqual(
        expected,
        try normalizationOutcome(config, .{}, input, .whole),
    );
    for (1..input.len) |split| {
        try std.testing.expectEqual(
            expected,
            try normalizationOutcome(config, .{}, input, .{ .split = split }),
        );
    }
    inline for (.{ 1, 2, 3, 5, 7 }) |size| {
        try std.testing.expectEqual(
            expected,
            try normalizationOutcome(config, .{}, input, .{ .fixed = size }),
        );
    }
    for (0..8) |seed| {
        try std.testing.expectEqual(
            expected,
            try normalizationOutcome(config, .{}, input, .{ .random = seed }),
        );
    }
}

fn expectExpandedName(
    name: xml.NameFor(NS_CONFIG),
    raw: []const u8,
    prefix: ?[]const u8,
    local: []const u8,
    namespace_uri: ?[]const u8,
) !void {
    try std.testing.expectEqualStrings(raw, name.raw);
    if (prefix) |expected| {
        try std.testing.expectEqualStrings(expected, name.prefix.?);
    } else {
        try std.testing.expect(name.prefix == null);
    }
    try std.testing.expectEqualStrings(local, name.local);
    if (namespace_uri) |expected| {
        try std.testing.expectEqualStrings(expected, name.namespace_uri.?);
    } else {
        try std.testing.expect(name.namespace_uri == null);
    }
}

const TextRun = struct {
    bytes: usize = 0,
    fragments: usize = 0,
};

fn drainTextBoundary(reader: *CoreReader, run: *TextRun) !bool {
    while (true) {
        switch (try reader.next()) {
            .event => |event| switch (event) {
                .text => |text| {
                    run.bytes += text.bytes.len;
                    run.fragments += 1;
                },
                else => {},
            },
            .need_input => return false,
            .done => return true,
        }
    }
}

fn parseRepeatedText(reader: *CoreReader, total_bytes: usize) !TextRun {
    var run: TextRun = .{};
    try reader.feed("<r>", false);
    try std.testing.expect(!try drainTextBoundary(reader, &run));

    const text_chunk: [257]u8 = @splat('x');
    var remaining = total_bytes;
    while (remaining > 0) {
        const len = @min(remaining, text_chunk.len);
        try reader.feed(text_chunk[0..len], false);
        try std.testing.expect(!try drainTextBoundary(reader, &run));
        remaining -= len;
    }

    try reader.feed("</r>", true);
    try std.testing.expect(try drainTextBoundary(reader, &run));
    return run;
}

const MarkupRun = struct {
    bytes: usize = 0,
    fragments: usize = 0,
    complete: usize = 0,
};

fn drainCommentBoundary(reader: *CoreReader, run: *MarkupRun) !bool {
    while (true) {
        switch (try reader.next()) {
            .event => |event| switch (event) {
                .comment => |comment| {
                    run.bytes += comment.bytes.len;
                    run.fragments += 1;
                    run.complete += @intFromBool(comment.complete);
                },
                else => {},
            },
            .need_input => return false,
            .done => return true,
        }
    }
}

fn parseRepeatedComment(reader: *CoreReader, total_bytes: usize) !MarkupRun {
    var run: MarkupRun = .{};
    try reader.feed("<r><!--", false);
    try std.testing.expect(!try drainCommentBoundary(reader, &run));

    const data: [257]u8 = @splat('x');
    var remaining = total_bytes;
    while (remaining > 0) {
        const len = @min(remaining, data.len);
        try reader.feed(data[0..len], false);
        try std.testing.expect(!try drainCommentBoundary(reader, &run));
        remaining -= len;
    }

    try reader.feed("--></r>", true);
    try std.testing.expect(try drainCommentBoundary(reader, &run));
    return run;
}

fn drainProcessingInstructionBoundary(reader: *CoreReader, run: *MarkupRun) !bool {
    while (true) {
        switch (try reader.next()) {
            .event => |event| switch (event) {
                .processing_instruction => |instruction| {
                    try std.testing.expectEqualStrings("target", instruction.target);
                    run.bytes += instruction.data.len;
                    run.fragments += 1;
                    run.complete += @intFromBool(instruction.complete);
                },
                else => {},
            },
            .need_input => return false,
            .done => return true,
        }
    }
}

fn parseRepeatedProcessingInstruction(reader: *CoreReader, total_bytes: usize) !MarkupRun {
    var run: MarkupRun = .{};
    try reader.feed("<r><?target ", false);
    try std.testing.expect(!try drainProcessingInstructionBoundary(reader, &run));

    const data: [257]u8 = @splat('x');
    var remaining = total_bytes;
    while (remaining > 0) {
        const len = @min(remaining, data.len);
        try reader.feed(data[0..len], false);
        try std.testing.expect(!try drainProcessingInstructionBoundary(reader, &run));
        remaining -= len;
    }

    try reader.feed("?></r>", true);
    try std.testing.expect(try drainProcessingInstructionBoundary(reader, &run));
    return run;
}

fn drainCore(reader: *CoreReader) !Summary {
    var summary: Summary = .{};
    while (true) {
        switch (try reader.next()) {
            .event => |event| try summary.observe(event),
            .need_input => return error.UnexpectedNeedInput,
            .done => return summary,
        }
    }
}

fn drainNamespace(reader: *xml.ReaderFor(NS_CONFIG)) !Summary {
    var summary: Summary = .{};
    while (true) switch (try reader.next()) {
        .event => |event| try summary.observe(event),
        .need_input => return error.UnexpectedNeedInput,
        .done => return summary,
    };
}

const NORMAL_ENGINE_CONFIG: xml.Config = .{
    .profile = .xml11_ns_nonvalidating,
    .event_locations = true,
    .external_sources = true,
};

fn appendFocusedValue(output: *std.ArrayList(u8), value: []const u8) !void {
    try output.appendSlice(std.testing.allocator, value);
    try output.append(std.testing.allocator, 0);
}

const NormalSummary = struct {
    events: []u8,
    source_encoding: xml.SourceEncoding,
    declared_encoding: [32]u8 = @splat(0),
    declared_encoding_len: usize = 0,
    logical_events: [64]u8 = @splat(0),
    logical_events_len: usize = 0,
    text_runs: [512]u8 = @splat(0),
    text_runs_len: usize = 0,
    final_text_fragments: usize = 0,
    final_text_span: ?xml.SourceSpan = null,
    attributes: usize = 0,
    attribute_values: [512]u8 = @splat(0),
    attribute_values_len: usize = 0,

    fn deinit(self: *NormalSummary) void {
        std.testing.allocator.free(self.events);
        self.* = undefined;
    }
};

fn appendNormalLogicalEvent(events: *[64]u8, len: *usize, value: u8) !void {
    if (len.* == events.len) return error.NormalEventSummaryTooLarge;
    events[len.*] = value;
    len.* += 1;
}

fn summarizeNormalSource(source: xml.Source) !NormalSummary {
    return summarizeNormalSourceWithOptions(source, .{});
}

fn summarizeNormalSourceWithOptions(
    source: xml.Source,
    options: xml.ReaderOptions,
) !NormalSummary {
    var reader = try xml.Reader.init(std.testing.allocator, source, options);
    defer reader.deinit();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(std.testing.allocator);
    var source_encoding: ?xml.SourceEncoding = null;
    var declared_encoding: [32]u8 = @splat(0);
    var declared_encoding_len: usize = 0;
    var text_origin: ?xml.TextOrigin = null;
    var comment_active = false;
    var instruction_active = false;
    var text_run_active = false;
    var logical_events: [64]u8 = @splat(0);
    var logical_events_len: usize = 0;
    var text_runs: [512]u8 = @splat(0);
    var text_runs_len: usize = 0;
    var final_text_fragments: usize = 0;
    var final_text_span: ?xml.SourceSpan = null;
    var attributes: usize = 0;
    var attribute_values: [512]u8 = @splat(0);
    var attribute_values_len: usize = 0;
    while (try reader.next()) |event| switch (event.data) {
        .document_start => |document| {
            source_encoding = document.source_encoding;
            if (document.declaration) |declaration| {
                if (declaration.encoding) |value| {
                    if (value.len > declared_encoding.len) {
                        return error.DeclaredEncodingSummaryTooLarge;
                    }
                    @memcpy(declared_encoding[0..value.len], value);
                    declared_encoding_len = value.len;
                }
            }
            try appendNormalLogicalEvent(&logical_events, &logical_events_len, 'D');
            try output.append(std.testing.allocator, 'D');
            try output.append(std.testing.allocator, @intFromEnum(document.effective_version));
        },
        .start_element => |element| {
            try appendNormalLogicalEvent(&logical_events, &logical_events_len, 'S');
            try output.append(std.testing.allocator, 'S');
            try appendFocusedValue(&output, element.name.raw);
            try appendFocusedValue(
                &output,
                element.name.expanded.?.namespace_uri orelse "",
            );
            for (element.attributes) |attribute| {
                attributes = std.math.add(usize, attributes, 1) catch
                    return error.NormalSummaryCountOverflow;
                const value_end = std.math.add(
                    usize,
                    attribute_values_len,
                    attribute.value.len,
                ) catch return error.NormalAttributeSummaryTooLarge;
                if (value_end >= attribute_values.len) {
                    return error.NormalAttributeSummaryTooLarge;
                }
                @memcpy(attribute_values[attribute_values_len..value_end], attribute.value);
                attribute_values[value_end] = 0;
                attribute_values_len = value_end + 1;
                try output.append(std.testing.allocator, 'A');
                try appendFocusedValue(&output, attribute.name.raw);
                try appendFocusedValue(&output, attribute.value);
            }
            for (element.namespace_declarations) |declaration| {
                try output.append(std.testing.allocator, 'N');
                try appendFocusedValue(&output, declaration.prefix orelse "");
                try appendFocusedValue(&output, declaration.namespace_uri);
            }
        },
        .end_element => |element| {
            try appendNormalLogicalEvent(&logical_events, &logical_events_len, 'E');
            try output.append(std.testing.allocator, 'E');
            try appendFocusedValue(&output, element.name.raw);
            try appendFocusedValue(
                &output,
                element.name.expanded.?.namespace_uri orelse "",
            );
        },
        .text => |value| {
            if (!text_run_active) {
                try appendNormalLogicalEvent(&logical_events, &logical_events_len, 'T');
                text_run_active = true;
            }
            if (text_origin == null or text_origin.? != value.origin) {
                try output.append(std.testing.allocator, 'T');
                try output.append(std.testing.allocator, @intFromEnum(value.origin));
                text_origin = value.origin;
            }
            try output.appendSlice(std.testing.allocator, value.bytes);
            const text_end = std.math.add(usize, text_runs_len, value.bytes.len) catch
                return error.TextRunSummaryTooLarge;
            if (text_end > text_runs.len) return error.TextRunSummaryTooLarge;
            @memcpy(text_runs[text_runs_len..text_end], value.bytes);
            text_runs_len = text_end;
            if (value.final_fragment) {
                if (text_runs_len == text_runs.len) return error.TextRunSummaryTooLarge;
                text_runs[text_runs_len] = 0;
                text_runs_len += 1;
                final_text_fragments = std.math.add(usize, final_text_fragments, 1) catch
                    return error.NormalSummaryCountOverflow;
                final_text_span = event.span;
                text_run_active = false;
                text_origin = null;
            }
        },
        .comment => |value| {
            if (!comment_active) {
                try appendNormalLogicalEvent(&logical_events, &logical_events_len, 'C');
                try output.append(std.testing.allocator, 'C');
                comment_active = true;
            }
            try output.appendSlice(std.testing.allocator, value.bytes);
            if (value.final_fragment) {
                try output.append(std.testing.allocator, 0);
                comment_active = false;
            }
        },
        .processing_instruction => |value| {
            if (!instruction_active) {
                try appendNormalLogicalEvent(&logical_events, &logical_events_len, 'P');
                try output.append(std.testing.allocator, 'P');
                try appendFocusedValue(&output, value.target);
                instruction_active = true;
            }
            try output.appendSlice(std.testing.allocator, value.data);
            if (value.final_fragment) {
                try output.append(std.testing.allocator, 0);
                instruction_active = false;
            }
        },
        .document_end => {
            try appendNormalLogicalEvent(&logical_events, &logical_events_len, 'Z');
            try output.append(std.testing.allocator, 'Z');
        },
        else => {},
    };
    if (text_run_active) return error.MissingFinalTextFragment;
    const detected_encoding = source_encoding orelse return error.MissingDocumentStart;
    return .{
        .events = try output.toOwnedSlice(std.testing.allocator),
        .source_encoding = detected_encoding,
        .declared_encoding = declared_encoding,
        .declared_encoding_len = declared_encoding_len,
        .logical_events = logical_events,
        .logical_events_len = logical_events_len,
        .text_runs = text_runs,
        .text_runs_len = text_runs_len,
        .final_text_fragments = final_text_fragments,
        .final_text_span = final_text_span,
        .attributes = attributes,
        .attribute_values = attribute_values,
        .attribute_values_len = attribute_values_len,
    };
}

fn summarizeNormalReader(input: []const u8) !NormalSummary {
    return summarizeNormalSource(.{ .slice = input });
}

fn expectNormalEncodingSummary(
    actual: *const NormalSummary,
    expected_events: []const u8,
    expected_encoding: xml.SourceEncoding,
    expected_declaration: ?[]const u8,
) !void {
    try std.testing.expectEqualStrings(expected_events, actual.events);
    try std.testing.expectEqual(expected_encoding, actual.source_encoding);
    if (expected_declaration) |value| {
        try std.testing.expectEqualStrings(
            value,
            actual.declared_encoding[0..actual.declared_encoding_len],
        );
    } else {
        try std.testing.expectEqual(@as(usize, 0), actual.declared_encoding_len);
    }
}

fn expectNormalEncodingSchedules(
    input: []const u8,
    expected_events: []const u8,
    expected_encoding: xml.SourceEncoding,
    expected_declaration: ?[]const u8,
) !void {
    return expectNormalEncodingSchedulesWithOptions(
        input,
        .{},
        expected_events,
        expected_encoding,
        expected_declaration,
    );
}

fn expectNormalEncodingSchedulesWithOptions(
    input: []const u8,
    options: xml.ReaderOptions,
    expected_events: []const u8,
    expected_encoding: xml.SourceEncoding,
    expected_declaration: ?[]const u8,
) !void {
    var slice = try summarizeNormalSourceWithOptions(.{ .slice = input }, options);
    defer slice.deinit();
    try expectNormalEncodingSummary(
        &slice,
        expected_events,
        expected_encoding,
        expected_declaration,
    );

    inline for (.{ 1, 2, 3, 5, 7 }) |chunk_size| {
        var input_buffer: [chunk_size]u8 = undefined;
        var source: std.testing.Reader = .init(
            &input_buffer,
            &.{.{ .buffer = input }},
        );
        source.artificial_limit = .limited(chunk_size);
        var streamed = try summarizeNormalSourceWithOptions(
            .{ .stream = &source.interface },
            options,
        );
        defer streamed.deinit();
        try expectNormalEncodingSummary(
            &streamed,
            expected_events,
            expected_encoding,
            expected_declaration,
        );
    }
}

const NormalFailure = struct {
    category: xml.ReadError,
    code: xml.DiagnosticCode,
    byte_offset: u64,
    related_byte_offset: ?u64,
    line: ?u64,
    byte_column: ?u64,
};

fn normalFailure(source: xml.Source) !NormalFailure {
    return normalFailureWithOptions(source, .{});
}

fn normalFailureWithOptions(
    source: xml.Source,
    options: xml.ReaderOptions,
) !NormalFailure {
    var reader = try xml.Reader.init(std.testing.allocator, source, options);
    defer reader.deinit();
    while (true) {
        const event = reader.next() catch |failure| {
            const diagnostic = reader.diagnostic() orelse return error.MissingDiagnostic;
            return .{
                .category = failure,
                .code = diagnostic.code,
                .byte_offset = diagnostic.primary.byte_offset,
                .related_byte_offset = if (diagnostic.related) |related|
                    related.byte_offset
                else
                    null,
                .line = diagnostic.primary.line,
                .byte_column = diagnostic.primary.byte_column,
            };
        };
        if (event == null) return error.ExpectedFailure;
    }
}

fn expectNormalFailureSchedules(input: []const u8, expected: NormalFailure) !void {
    return expectNormalFailureSchedulesWithOptions(input, .{}, expected);
}

fn expectNormalFailureSchedulesWithOptions(
    input: []const u8,
    options: xml.ReaderOptions,
    expected: NormalFailure,
) !void {
    try std.testing.expectEqual(
        expected,
        try normalFailureWithOptions(.{ .slice = input }, options),
    );
    inline for (.{ 1, 2, 3, 5, 7 }) |chunk_size| {
        var input_buffer: [chunk_size]u8 = undefined;
        var source: std.testing.Reader = .init(
            &input_buffer,
            &.{.{ .buffer = input }},
        );
        source.artificial_limit = .limited(chunk_size);
        try std.testing.expectEqual(
            expected,
            try normalFailureWithOptions(.{ .stream = &source.interface }, options),
        );
    }
}

fn pairEncode(output: []u8, input: []const u8) void {
    std.debug.assert(output.len == input.len * 2);
    for (input, 0..) |byte, index| {
        output[index * 2] = 0;
        output[index * 2 + 1] = byte;
    }
}

fn pairTranscode(
    _: ?*anyopaque,
    input: []const u8,
    final: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    if (input.len < 2) {
        if (final and input.len != 0) return .{ .malformed = 0 };
        return .need_input;
    }
    if (input[0] != 0) return .{ .malformed = 0 };
    if (output.len == 0) return .need_output;
    output[0] = input[1];
    source_advances[0] = 2;
    return .{ .progress = .{ .consumed = 2, .produced = 1 } };
}

fn pairTranscoder() xml.Transcoder {
    return .{ .context = null, .runFn = pairTranscode };
}

fn markedEncode(output: []u8, input: []const u8, marked: u8) []u8 {
    var len: usize = 0;
    for (input) |byte| {
        if (byte == marked) {
            output[len] = 0;
            len += 1;
        }
        output[len] = byte;
        len += 1;
    }
    return output[0..len];
}

fn markedTranscode(
    _: ?*anyopaque,
    input: []const u8,
    final: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    if (input.len == 0) return .need_input;
    const consumed: usize = if (input[0] == 0) 2 else 1;
    if (input.len < consumed) {
        if (final) return .{ .malformed = 0 };
        return .need_input;
    }
    if (output.len == 0) return .need_output;
    output[0] = input[consumed - 1];
    source_advances[0] = @intCast(consumed);
    return .{ .progress = .{ .consumed = consumed, .produced = 1 } };
}

fn markedTranscoder() xml.Transcoder {
    return .{ .context = null, .runFn = markedTranscode };
}

fn latin1Transcode(
    _: ?*anyopaque,
    input: []const u8,
    _: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    if (input.len == 0) return .need_input;
    if (input[0] == 0xe9) {
        if (output.len < 2) return .need_output;
        output[0] = 0xc3;
        output[1] = 0xa9;
        source_advances[0] = 0;
        source_advances[1] = 1;
        return .{ .progress = .{ .consumed = 1, .produced = 2 } };
    }
    if (output.len == 0) return .need_output;
    output[0] = input[0];
    source_advances[0] = 1;
    return .{ .progress = .{ .consumed = 1, .produced = 1 } };
}

fn latin1Transcoder() xml.Transcoder {
    return .{ .context = null, .runFn = latin1Transcode };
}

const InvalidTranscodeResult = enum {
    consumed_over_input,
    produced_over_output,
    zero_consumed,
    zero_produced,
    wrong_source_advance,
    source_advance_over,
    malformed_offset,
    final_need_input,
};

fn invalidTranscode(
    context: ?*anyopaque,
    input: []const u8,
    _: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    const result: *const InvalidTranscodeResult = @ptrCast(@alignCast(context.?));
    return switch (result.*) {
        .consumed_over_input => .{ .progress = .{
            .consumed = input.len + 1,
            .produced = 1,
        } },
        .produced_over_output => .{ .progress = .{
            .consumed = 1,
            .produced = output.len + 1,
        } },
        .zero_consumed => .{ .progress = .{ .consumed = 0, .produced = 1 } },
        .zero_produced => .{ .progress = .{ .consumed = 1, .produced = 0 } },
        .wrong_source_advance => result: {
            output[0] = 'x';
            source_advances[0] = 0;
            break :result .{ .progress = .{ .consumed = 1, .produced = 1 } };
        },
        .source_advance_over => result: {
            output[0] = 'x';
            source_advances[0] = 2;
            break :result .{ .progress = .{ .consumed = 1, .produced = 1 } };
        },
        .malformed_offset => .{ .malformed = input.len + 1 },
        .final_need_input => .need_input,
    };
}

const FixedTranscodeResult = enum { need_output, unsupported, cancelled };

fn fixedTranscodeResult(
    context: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: []u8,
    _: []u8,
) xml.TranscodeStep {
    const result: *const FixedTranscodeResult = @ptrCast(@alignCast(context.?));
    return switch (result.*) {
        .need_output => .need_output,
        .unsupported => .unsupported,
        .cancelled => .cancelled,
    };
}

fn rootTranscoderAllocationAttempt(allocator: std.mem.Allocator) !void {
    const logical = "<?xml version='1.0' encoding='PAIR'?><root>é</root>";
    var encoded: [logical.len * 2]u8 = undefined;
    pairEncode(&encoded, logical);
    var input_buffer: [1]u8 = undefined;
    var source: std.testing.Reader = .init(
        &input_buffer,
        &.{.{ .buffer = &encoded }},
    );
    source.artificial_limit = .limited(1);
    var reader = try xml.Reader.init(
        allocator,
        .{ .stream = &source.interface },
        .{ .transcoder = pairTranscoder() },
    );
    defer reader.deinit();
    while (try reader.next()) |_| {}
}

const TranscodeCallCounter = struct {
    calls: usize = 0,
};

fn cancellingTranscode(
    context: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: []u8,
    _: []u8,
) xml.TranscodeStep {
    const counter: *TranscodeCallCounter = @ptrCast(@alignCast(context.?));
    counter.calls += 1;
    return .cancelled;
}

fn invalidUtf8Transcode(
    _: ?*anyopaque,
    input: []const u8,
    _: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    if (input.len == 0) return .need_input;
    if (output.len == 0) return .need_output;
    output[0] = 0xff;
    source_advances[0] = 1;
    return .{ .progress = .{ .consumed = 1, .produced = 1 } };
}

fn finalIdentityTranscode(
    _: ?*anyopaque,
    input: []const u8,
    final: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    if (input.len == 0) return .need_input;
    if (!final) return .need_input;
    if (output.len == 0) return .need_output;
    output[0] = input[0];
    source_advances[0] = 1;
    return .{ .progress = .{ .consumed = 1, .produced = 1 } };
}

fn prefixedIdentityTranscode(
    _: ?*anyopaque,
    input: []const u8,
    final: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    const prefix = "\xef\xbb\xbf";
    if (input.len == 0) return .need_input;
    if (std.mem.startsWith(u8, input, prefix)) {
        if (input.len == prefix.len) {
            return if (final) .{ .malformed = 0 } else .need_input;
        }
        if (output.len == 0) return .need_output;
        output[0] = input[prefix.len];
        source_advances[0] = prefix.len + 1;
        return .{ .progress = .{ .consumed = prefix.len + 1, .produced = 1 } };
    }
    if (output.len == 0) return .need_output;
    output[0] = input[0];
    source_advances[0] = 1;
    return .{ .progress = .{ .consumed = 1, .produced = 1 } };
}

const ProgressThenUnsupported = struct {
    progressed: bool = false,
};

fn progressThenUnsupported(
    context: ?*anyopaque,
    input: []const u8,
    _: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    const state: *ProgressThenUnsupported = @ptrCast(@alignCast(context.?));
    if (state.progressed) return .unsupported;
    if (input.len == 0) return .need_input;
    if (output.len == 0) return .need_output;
    state.progressed = true;
    output[0] = '<';
    source_advances[0] = 1;
    return .{ .progress = .{ .consumed = 1, .produced = 1 } };
}

fn summarizeSelectedEngine(input: []const u8) ![]u8 {
    const Reader = xml.ReaderFor(NORMAL_ENGINE_CONFIG);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(std.testing.allocator);
    while (true) switch (try reader.next()) {
        .need_input => return error.UnexpectedNeedInput,
        .done => return output.toOwnedSlice(std.testing.allocator),
        .event => |located| switch (located.payload) {
            .document_start => |document| {
                try output.append(std.testing.allocator, 'D');
                try output.append(std.testing.allocator, @intFromEnum(document.effective_version));
            },
            .start_element => |element| {
                try output.append(std.testing.allocator, 'S');
                try appendFocusedValue(&output, element.name.raw);
                try appendFocusedValue(&output, element.name.namespace_uri orelse "");
                for (element.attributes) |attribute| {
                    try output.append(std.testing.allocator, 'A');
                    try appendFocusedValue(&output, attribute.name.raw);
                    try appendFocusedValue(&output, attribute.value);
                }
                for (element.namespace_declarations) |declaration| {
                    try output.append(std.testing.allocator, 'N');
                    try appendFocusedValue(&output, declaration.prefix orelse "");
                    try appendFocusedValue(&output, declaration.namespace_uri);
                }
            },
            .end_element => |element| {
                try output.append(std.testing.allocator, 'E');
                try appendFocusedValue(&output, element.name.raw);
                try appendFocusedValue(&output, element.name.namespace_uri orelse "");
            },
            .text => |value| {
                try output.append(std.testing.allocator, 'T');
                try output.append(std.testing.allocator, @intFromEnum(value.origin));
                try output.appendSlice(std.testing.allocator, value.bytes);
            },
            .document_end => try output.append(std.testing.allocator, 'Z'),
            else => {},
        },
    };
}

test "[integration] - [Reader]: matches selected engine output and first failure" {
    const input = "<root xmlns='urn:test' id='7'>value</root>";
    var normal = try summarizeNormalReader(input);
    defer normal.deinit();
    const selected = try summarizeSelectedEngine(input);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings(selected, normal.events);

    var normal_reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<root>" },
        .{},
    );
    defer normal_reader.deinit();
    var normal_failure: ?anyerror = null;
    while (true) {
        const event = normal_reader.next() catch |failure| {
            normal_failure = failure;
            break;
        };
        if (event == null) break;
    }
    try std.testing.expectEqual(error.InvalidXml, normal_failure.?);

    const SelectedReader = xml.ReaderFor(NORMAL_ENGINE_CONFIG);
    var selected_reader = try SelectedReader.init(std.testing.allocator, .{});
    defer selected_reader.deinit();
    try selected_reader.feed("<root>", true);
    var selected_failure: ?anyerror = null;
    while (true) {
        const step = selected_reader.next() catch |failure| {
            selected_failure = failure;
            break;
        };
        if (step == .done) break;
    }
    try std.testing.expectEqual(error.InvalidXml, selected_failure.?);
    try std.testing.expectEqual(
        selected_reader.diagnostic().?.code,
        normal_reader.diagnostic().?.code,
    );
    try std.testing.expectEqual(
        selected_reader.diagnostic().?.primary.source_id,
        normal_reader.diagnostic().?.primary.source_id,
    );
    try std.testing.expectEqual(
        selected_reader.diagnostic().?.primary.byte_offset,
        normal_reader.diagnostic().?.primary.byte_offset,
    );
    try std.testing.expectEqual(
        selected_reader.diagnostic().?.primary.line,
        normal_reader.diagnostic().?.primary.line.?,
    );
    try std.testing.expectEqual(
        selected_reader.diagnostic().?.primary.byte_column,
        normal_reader.diagnostic().?.primary.byte_column.?,
    );
}

test "[property] - [Reader source]: slice and buffered schedules agree" {
    const input =
        " \n<?setup ready?><root xmlns='urn:test' id='7 &amp; 8'>" ++
        "pre&amp;<![CDATA[mid]]><item child='ok &amp; ready'/>post<!--note-->" ++
        "tail<?inside data?>done</root>\n";
    var expected = try summarizeNormalReader(input);
    defer expected.deinit();
    try std.testing.expectEqualStrings(
        "DPSTSETCTPTEZ",
        expected.logical_events[0..expected.logical_events_len],
    );
    try std.testing.expectEqualStrings(
        "pre&mid\x00post\x00tail\x00done\x00",
        expected.text_runs[0..expected.text_runs_len],
    );
    try std.testing.expectEqual(@as(usize, 4), expected.final_text_fragments);
    const text_end = std.mem.indexOf(u8, input, "</root>").?;
    try std.testing.expectEqual(xml.SourceSpan{
        .source_id = 0,
        .start = text_end,
        .end = text_end,
    }, expected.final_text_span.?);
    try std.testing.expectEqual(@as(usize, 2), expected.attributes);
    try std.testing.expectEqualStrings(
        "7 & 8\x00ok & ready\x00",
        expected.attribute_values[0..expected.attribute_values_len],
    );

    var one_byte_buffer: [1]u8 = undefined;
    var one_byte_source: std.testing.Reader = .init(
        &one_byte_buffer,
        &.{.{ .buffer = input }},
    );
    one_byte_source.artificial_limit = .limited(1);
    var one_byte = try summarizeNormalSource(.{ .stream = &one_byte_source.interface });
    defer one_byte.deinit();
    try std.testing.expectEqualStrings(expected.events, one_byte.events);
    try std.testing.expectEqual(expected.source_encoding, one_byte.source_encoding);
    try std.testing.expectEqualSlices(
        u8,
        expected.logical_events[0..expected.logical_events_len],
        one_byte.logical_events[0..one_byte.logical_events_len],
    );
    try std.testing.expectEqualSlices(
        u8,
        expected.text_runs[0..expected.text_runs_len],
        one_byte.text_runs[0..one_byte.text_runs_len],
    );
    try std.testing.expectEqual(expected.final_text_fragments, one_byte.final_text_fragments);
    try std.testing.expectEqual(expected.final_text_span, one_byte.final_text_span);
    try std.testing.expectEqual(expected.attributes, one_byte.attributes);
    try std.testing.expectEqualSlices(
        u8,
        expected.attribute_values[0..expected.attribute_values_len],
        one_byte.attribute_values[0..one_byte.attribute_values_len],
    );

    var split_buffer: [7]u8 = undefined;
    var split_source: std.testing.Reader = .init(&split_buffer, &.{
        .{ .buffer = "" },
        .{ .buffer = " \n<?setup ready?><ro" },
        .{ .buffer = "ot xmlns='urn:test' id='7 &amp; 8'>pre&amp;<![CDATA[mi" },
        .{ .buffer = "d]]><item child='ok &amp; ready'/>post<!--no" },
        .{ .buffer = "te-->tail<?inside data?>done</root>\n" },
    });
    split_source.artificial_limit = .limited(3);
    var split = try summarizeNormalSource(.{ .stream = &split_source.interface });
    defer split.deinit();
    try std.testing.expectEqualStrings(expected.events, split.events);
    try std.testing.expectEqual(expected.source_encoding, split.source_encoding);
    try std.testing.expectEqualSlices(
        u8,
        expected.logical_events[0..expected.logical_events_len],
        split.logical_events[0..split.logical_events_len],
    );
    try std.testing.expectEqualSlices(
        u8,
        expected.text_runs[0..expected.text_runs_len],
        split.text_runs[0..split.text_runs_len],
    );
    try std.testing.expectEqual(expected.final_text_fragments, split.final_text_fragments);
    try std.testing.expectEqual(expected.final_text_span, split.final_text_span);
    try std.testing.expectEqual(expected.attributes, split.attributes);
    try std.testing.expectEqualSlices(
        u8,
        expected.attribute_values[0..expected.attribute_values_len],
        split.attribute_values[0..split.attribute_values_len],
    );

    const malformed = "<root><item></root>";
    const expected_failure = try normalFailure(.{ .slice = malformed });
    var failure_buffer: [2]u8 = undefined;
    var failure_source: std.testing.Reader = .init(
        &failure_buffer,
        &.{.{ .buffer = malformed }},
    );
    failure_source.artificial_limit = .limited(1);
    try std.testing.expectEqual(
        expected_failure,
        try normalFailure(.{ .stream = &failure_source.interface }),
    );

    const expected_empty = try normalFailure(.{ .slice = "" });
    var empty_buffer: [1]u8 = undefined;
    var empty_source: std.testing.Reader = .init(&empty_buffer, &.{});
    try std.testing.expectEqual(
        expected_empty,
        try normalFailure(.{ .stream = &empty_source.interface }),
    );
}

test "[failure] - [Reader grammar]: first failures are exact across source schedules" {
    const double_hyphen = "<root><!-- invalid -- comment --></root>\n";
    const unclosed_cdata = "<root><![CDATA[never closed</root>";
    const unsupported_version = "<?xml version=\"2.0\"?><root/>\n";
    const cases = [_]struct {
        input: []const u8,
        category: xml.ReadError,
        code: xml.DiagnosticCode,
        offset: u64,
        related: ?u64 = null,
    }{
        .{ .input = "", .category = error.InvalidXml, .code = .empty_document, .offset = 0 },
        .{
            .input = "<root><item></root>\n",
            .category = error.InvalidXml,
            .code = .mismatched_end_tag,
            .offset = 14,
            .related = 6,
        },
        .{
            .input = "<root value=\"one\" value=\"two\"/>\n",
            .category = error.InvalidXml,
            .code = .duplicate_attribute,
            .offset = 18,
            .related = 6,
        },
        .{
            .input = "<root>&#xZZ;</root>\n",
            .category = error.InvalidXml,
            .code = .malformed_reference,
            .offset = 9,
        },
        .{
            .input = double_hyphen,
            .category = error.InvalidXml,
            .code = .malformed_comment,
            .offset = std.mem.indexOf(u8, double_hyphen, "-- comment").? + 2,
        },
        .{
            .input = "<root><?XmL reserved?></root>\n",
            .category = error.InvalidXml,
            .code = .reserved_processing_instruction_target,
            .offset = 6,
        },
        .{
            .input = unclosed_cdata,
            .category = error.InvalidXml,
            .code = .unclosed_cdata,
            .offset = unclosed_cdata.len,
        },
        .{
            .input = unsupported_version,
            .category = error.UnsupportedVersion,
            .code = .unsupported_version,
            .offset = std.mem.indexOf(u8, unsupported_version, "2.0").?,
        },
        .{
            .input = "<1root/>",
            .category = error.InvalidXml,
            .code = .malformed_start_tag,
            .offset = 1,
        },
    };
    for (cases) |case| {
        try expectNormalFailureSchedulesWithOptions(
            case.input,
            .{ .namespaces = .raw, .dtd = .reject },
            .{
                .category = case.category,
                .code = case.code,
                .byte_offset = case.offset,
                .related_byte_offset = case.related,
                .line = 1,
                .byte_column = case.offset + 1,
            },
        );
    }
}

test "[property] - [Reader decoder]: built-in encodings preserve events across source schedules" {
    const logical = "<根 属性='值'>one\r\ntwo🙂</根>";
    var expected = try summarizeNormalReader(logical);
    defer expected.deinit();

    try expectNormalEncodingSchedules(
        "\xef\xbb\xbf" ++ logical,
        expected.events,
        .utf8,
        null,
    );

    const little = try encodeUtf16(std.testing.allocator, logical, .little, true);
    defer std.testing.allocator.free(little);
    try expectNormalEncodingSchedules(little, expected.events, .utf16_le, null);

    const big = try encodeUtf16(std.testing.allocator, logical, .big, true);
    defer std.testing.allocator.free(big);
    try expectNormalEncodingSchedules(big, expected.events, .utf16_be, null);

    var explicit_expected = try summarizeNormalReader("<root>λ🙂</root>");
    defer explicit_expected.deinit();
    try expectNormalEncodingSchedules(
        UTF16LE_BOM,
        explicit_expected.events,
        .utf16_le,
        "UTF-16",
    );
    try expectNormalEncodingSchedules(
        UTF16BE_BOM,
        explicit_expected.events,
        .utf16_be,
        "UTF-16",
    );

    const xml11_normalized =
        "<?xml version='1.1'?><root>A\nB\nC\nD</root>";
    var xml11_expected = try summarizeNormalReader(xml11_normalized);
    defer xml11_expected.deinit();
    const xml11 =
        "<?xml version='1.1'?><root>A\xc2\x85B\xe2\x80\xa8C\r\xc2\x85D</root>";
    try expectNormalEncodingSchedules(
        xml11,
        xml11_expected.events,
        .utf8,
        null,
    );

    const xml11_little = try encodeUtf16(
        std.testing.allocator,
        xml11,
        .little,
        true,
    );
    defer std.testing.allocator.free(xml11_little);
    try expectNormalEncodingSchedules(
        xml11_little,
        xml11_expected.events,
        .utf16_le,
        null,
    );

    const xml11_big = try encodeUtf16(
        std.testing.allocator,
        xml11,
        .big,
        true,
    );
    defer std.testing.allocator.free(xml11_big);
    try expectNormalEncodingSchedules(
        xml11_big,
        xml11_expected.events,
        .utf16_be,
        null,
    );
}

test "[unit] - [Transcoder]: validates bounded callback results" {
    var output: [4]u8 = undefined;
    var source_advances: [4]u8 = undefined;
    const transcoder = pairTranscoder();

    const progress = try transcoder.run("\x00x", true, &output, &source_advances);
    try std.testing.expectEqual(@as(usize, 2), progress.progress.consumed);
    try std.testing.expectEqual(@as(usize, 1), progress.progress.produced);
    try std.testing.expectEqualStrings("x", output[0..1]);
    try std.testing.expectEqual(@as(u8, 2), source_advances[0]);
    try std.testing.expect((try transcoder.run("\x00", false, &output, &source_advances)) == .need_input);
    try std.testing.expect((try transcoder.run("\x00x", false, output[0..0], source_advances[0..0])) == .need_output);
    try std.testing.expectEqual(
        @as(usize, 0),
        (try transcoder.run("x", true, &output, &source_advances)).malformed,
    );

    const expanded = try latin1Transcoder().run("\xe9", true, &output, &source_advances);
    try std.testing.expectEqual(@as(usize, 1), expanded.progress.consumed);
    try std.testing.expectEqual(@as(usize, 2), expanded.progress.produced);
    try std.testing.expectEqualStrings("é", output[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, source_advances[0..2]);

    inline for (std.meta.tags(InvalidTranscodeResult)) |result| {
        var invalid_result = result;
        const invalid: xml.Transcoder = .{
            .context = &invalid_result,
            .runFn = invalidTranscode,
        };
        try std.testing.expectError(
            error.InvalidResult,
            invalid.run("x", true, &output, &source_advances),
        );
    }
    try std.testing.expectError(
        error.InvalidResult,
        transcoder.run("\x00x", true, &output, source_advances[0..3]),
    );

    inline for (std.meta.tags(FixedTranscodeResult)) |result| {
        var fixed = result;
        const callback: xml.Transcoder = .{ .context = &fixed, .runFn = fixedTranscodeResult };
        const observed = try callback.run("", true, &output, &source_advances);
        try std.testing.expectEqualStrings(@tagName(result), @tagName(observed));
    }
}

test "[property] - [Reader transcoder]: root bytes preserve events across source schedules" {
    const content = "<根 属性='值'>one\r\ntwo🙂</根>";
    const logical = "<?xml version='1.0' encoding='PAIR'?>" ++ content;
    var encoded: [logical.len * 2]u8 = undefined;
    pairEncode(&encoded, logical);
    const options: xml.ReaderOptions = .{ .transcoder = pairTranscoder() };

    var expected = try summarizeNormalReader(content);
    defer expected.deinit();
    var slice = try summarizeNormalSourceWithOptions(.{ .slice = &encoded }, options);
    defer slice.deinit();
    try expectNormalEncodingSummary(&slice, expected.events, .other, "PAIR");

    inline for (.{ 1, 2, 3, 5, 7 }) |chunk_size| {
        var input_buffer: [chunk_size]u8 = undefined;
        var source: std.testing.Reader = .init(
            &input_buffer,
            &.{.{ .buffer = &encoded }},
        );
        source.artificial_limit = .limited(chunk_size);
        var streamed = try summarizeNormalSourceWithOptions(
            .{ .stream = &source.interface },
            options,
        );
        defer streamed.deinit();
        try expectNormalEncodingSummary(&streamed, expected.events, .other, "PAIR");
    }

    const latin1 = "<?xml version='1.0' encoding='ISO-8859-1'?><r>\xe9</r>";
    var latin1_expected = try summarizeNormalReader("<r>é</r>");
    defer latin1_expected.deinit();
    var latin1_summary = try summarizeNormalSourceWithOptions(
        .{ .slice = latin1 },
        .{ .transcoder = latin1Transcoder() },
    );
    defer latin1_summary.deinit();
    try expectNormalEncodingSummary(
        &latin1_summary,
        latin1_expected.events,
        .other,
        "ISO-8859-1",
    );

    const final_logical = "<r/>";
    var final_expected = try summarizeNormalReader(final_logical);
    defer final_expected.deinit();
    const final_options: xml.ReaderOptions = .{ .transcoder = .{
        .context = null,
        .runFn = finalIdentityTranscode,
    } };
    var final_slice = try summarizeNormalSourceWithOptions(
        .{ .slice = final_logical },
        final_options,
    );
    defer final_slice.deinit();
    try expectNormalEncodingSummary(&final_slice, final_expected.events, .other, null);

    var final_buffer: [1]u8 = undefined;
    var final_source: std.testing.Reader = .init(
        &final_buffer,
        &.{.{ .buffer = final_logical }},
    );
    final_source.artificial_limit = .limited(1);
    var final_stream = try summarizeNormalSourceWithOptions(
        .{ .stream = &final_source.interface },
        final_options,
    );
    defer final_stream.deinit();
    try expectNormalEncodingSummary(&final_stream, final_expected.events, .other, null);
}

test "[property] - [Reader transcoder]: XML 1.1 line endings survive source schedules" {
    const logical =
        "<?xml version='1.1' encoding='PAIR'?>\xc2\x85" ++
        "<root a='A\xc2\x85B'>A\xc2\x85B\xe2\x80\xa8C\r\xc2\x85D</root>";
    var encoded: [logical.len * 2]u8 = undefined;
    pairEncode(&encoded, logical);

    var expected = try summarizeNormalReader(
        "<?xml version='1.1'?>\n<root a='A B'>A\nB\nC\nD</root>",
    );
    defer expected.deinit();
    try expectNormalEncodingSchedulesWithOptions(
        &encoded,
        .{ .transcoder = pairTranscoder() },
        expected.events,
        .other,
        "PAIR",
    );
}

test "[integration] - [Reader transcoder]: event and failure locations use source bytes" {
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<r>\xe9</r>" },
        .{ .transcoder = latin1Transcoder() },
    );
    defer reader.deinit();

    var start_seen = false;
    var text_seen = false;
    var text_complete = false;
    var end_seen = false;
    while (try reader.next()) |event| switch (event.data) {
        .start_element => {
            try std.testing.expectEqual(@as(u64, 0), event.span.start);
            try std.testing.expectEqual(@as(u64, 3), event.span.end);
            start_seen = true;
        },
        .text => |text| {
            if (text.final_fragment) {
                try std.testing.expectEqual(@as(usize, 0), text.bytes.len);
                try std.testing.expectEqual(@as(u64, 4), event.span.start);
                try std.testing.expectEqual(@as(u64, 4), event.span.end);
                text_complete = true;
            } else {
                try std.testing.expectEqualStrings("é", text.bytes);
                try std.testing.expectEqual(@as(u64, 3), event.span.start);
                try std.testing.expectEqual(@as(u64, 4), event.span.end);
                text_seen = true;
            }
        },
        .end_element => {
            try std.testing.expectEqual(@as(u64, 4), event.span.start);
            try std.testing.expectEqual(@as(u64, 8), event.span.end);
            end_seen = true;
        },
        else => {},
    };
    try std.testing.expect(start_seen and text_seen and text_complete and end_seen);

    const mismatch_source = "<r>\r\n<x></y></r>";
    var mismatch_storage: [mismatch_source.len * 2]u8 = undefined;
    const mismatch_input = markedEncode(&mismatch_storage, mismatch_source, 'y');
    const mismatch = std.mem.indexOfScalar(u8, mismatch_source, 'y').?;
    const related = std.mem.indexOf(u8, mismatch_source, "<x").?;
    const line_start = std.mem.indexOfScalar(u8, mismatch_source, '\n').? + 1;
    try expectNormalFailureSchedulesWithOptions(
        mismatch_input,
        .{ .transcoder = markedTranscoder() },
        .{
            .category = error.InvalidXml,
            .code = .mismatched_end_tag,
            .byte_offset = mismatch,
            .related_byte_offset = related,
            .line = 2,
            .byte_column = mismatch - line_start + 1,
        },
    );

    const declaration_source = "<?xml version='2.0'?><r/>";
    var declaration_storage: [declaration_source.len * 2]u8 = undefined;
    const declaration_input = markedEncode(&declaration_storage, declaration_source, 'v');
    const version = std.mem.indexOfScalar(u8, declaration_source, '2').? + 1;
    try expectNormalFailureSchedulesWithOptions(
        declaration_input,
        .{ .transcoder = markedTranscoder() },
        .{
            .category = error.UnsupportedVersion,
            .code = .unsupported_version,
            .byte_offset = version,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = version + 1,
        },
    );
}

test "[failure] - [Reader transcoder]: final and callback failures are exact" {
    const invalid_result = NormalFailure{
        .category = error.InvalidEncoding,
        .code = .malformed_encoding,
        .byte_offset = 0,
        .related_byte_offset = null,
        .line = 1,
        .byte_column = 1,
    };
    inline for (std.meta.tags(InvalidTranscodeResult)) |result| {
        var invalid = result;
        try expectNormalFailureSchedulesWithOptions(
            "x",
            .{ .transcoder = .{ .context = &invalid, .runFn = invalidTranscode } },
            invalid_result,
        );
    }

    var need_output = FixedTranscodeResult.need_output;
    try expectNormalFailureSchedulesWithOptions(
        "x",
        .{ .transcoder = .{ .context = &need_output, .runFn = fixedTranscodeResult } },
        invalid_result,
    );
    var unsupported = FixedTranscodeResult.unsupported;
    try expectNormalFailureSchedulesWithOptions(
        "x",
        .{ .transcoder = .{ .context = &unsupported, .runFn = fixedTranscodeResult } },
        .{
            .category = error.UnsupportedEncoding,
            .code = .unsupported_encoding,
            .byte_offset = 0,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = 1,
        },
    );
    var progressed: ProgressThenUnsupported = .{};
    try std.testing.expectEqual(
        NormalFailure{
            .category = error.UnsupportedEncoding,
            .code = .unsupported_encoding,
            .byte_offset = 1,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = 2,
        },
        try normalFailureWithOptions(
            .{ .slice = "xx" },
            .{ .transcoder = .{
                .context = &progressed,
                .runFn = progressThenUnsupported,
            } },
        ),
    );
    try expectNormalFailureSchedulesWithOptions(
        "x",
        .{ .transcoder = .{ .context = null, .runFn = invalidUtf8Transcode } },
        .{
            .category = error.InvalidEncoding,
            .code = .malformed_utf8,
            .byte_offset = 0,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = 1,
        },
    );

    const logical = "<r/>";
    var incomplete: [logical.len * 2 + 1]u8 = undefined;
    pairEncode(incomplete[0 .. incomplete.len - 1], logical);
    incomplete[incomplete.len - 1] = 0;
    try expectNormalFailureSchedulesWithOptions(
        &incomplete,
        .{ .transcoder = pairTranscoder() },
        .{
            .category = error.InvalidEncoding,
            .code = .malformed_encoding,
            .byte_offset = incomplete.len - 1,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = incomplete.len,
        },
    );
}

test "[integration] - [Reader transcoder]: cancellation is sticky and reset replaces the callback" {
    var counter: TranscodeCallCounter = .{};
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "x" },
        .{ .transcoder = .{ .context = &counter, .runFn = cancellingTranscode } },
    );
    defer reader.deinit();

    try std.testing.expectError(error.Cancelled, reader.next());
    try std.testing.expectEqual(xml.DiagnosticCode.transcoder_cancelled, reader.diagnostic().?.code);
    try std.testing.expectEqual(@as(u64, 0), reader.diagnostic().?.primary.byte_offset);
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    try std.testing.expectError(error.Cancelled, reader.next());
    try std.testing.expectEqual(@as(usize, 1), counter.calls);

    try reader.reset(.{ .slice = "<ok/>" }, .{}, .retain_capacity);
    while (try reader.next()) |_| {}

    const logical = "<again/>";
    var encoded: [logical.len * 2]u8 = undefined;
    pairEncode(&encoded, logical);
    try reader.reset(
        .{ .slice = &encoded },
        .{ .transcoder = pairTranscoder() },
        .retain_capacity,
    );
    var source_encoding: ?xml.SourceEncoding = null;
    while (try reader.next()) |event| switch (event.data) {
        .document_start => |document| source_encoding = document.source_encoding,
        else => {},
    };
    try std.testing.expectEqual(xml.SourceEncoding.other, source_encoding.?);
}

test "[failure] - [Reader transcoder]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        rootTranscoderAllocationAttempt,
        .{},
    );

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var reader = try xml.Reader.init(
        failing.allocator(),
        .{ .slice = "x" },
        .{ .transcoder = pairTranscoder() },
    );
    defer reader.deinit();
    try reader.reset(
        .{ .slice = "x" },
        .{ .transcoder = markedTranscoder() },
        .release_memory,
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "[failure] - [Reader decoder]: malformed and incomplete input keeps physical locations" {
    const malformed_utf8 = [_]struct {
        input: []const u8,
        offset: u64,
    }{
        .{ .input = "<root>\x80</root>", .offset = 6 },
        .{ .input = "<root>\xe2(</root>", .offset = 7 },
        .{ .input = "<root>\xed\xa0\x80</root>", .offset = 7 },
    };
    for (malformed_utf8) |case| {
        try expectNormalFailureSchedules(case.input, .{
            .category = error.InvalidEncoding,
            .code = .malformed_utf8,
            .byte_offset = case.offset,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = case.offset + 1,
        });
    }

    const incomplete_utf8 = "<root>\xe2\x82";
    try expectNormalFailureSchedules(incomplete_utf8, .{
        .category = error.InvalidEncoding,
        .code = .malformed_utf8,
        .byte_offset = 6,
        .related_byte_offset = null,
        .line = 1,
        .byte_column = 7,
    });

    const utf16_cases = [_]struct {
        input: []const u8,
        offset: u64,
    }{
        .{ .input = UTF16LE_ODD_BYTE, .offset = UTF16LE_ODD_BYTE.len - 1 },
        .{ .input = UTF16LE_UNPAIRED_HIGH, .offset = 14 },
        .{ .input = UTF16BE_UNPAIRED_LOW, .offset = 14 },
    };
    for (utf16_cases) |case| {
        try expectNormalFailureSchedules(case.input, .{
            .category = error.InvalidEncoding,
            .code = .malformed_encoding,
            .byte_offset = case.offset,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = case.offset - 1,
        });
    }

    try expectNormalFailureSchedules("\x00\x00\xfe\xff", .{
        .category = error.UnsupportedEncoding,
        .code = .unsupported_encoding,
        .byte_offset = 0,
        .related_byte_offset = null,
        .line = 1,
        .byte_column = 1,
    });
}

test "[failure] - [Reader decoder]: signatures and declarations fail at original bytes" {
    const unsigned_source = "<?xml version='1.0'?><r/>";
    const unsigned = try encodeUtf16(
        std.testing.allocator,
        unsigned_source,
        .big,
        false,
    );
    defer std.testing.allocator.free(unsigned);
    try expectNormalFailureSchedules(unsigned, .{
        .category = error.InvalidEncoding,
        .code = .missing_encoding_signature,
        .byte_offset = 0,
        .related_byte_offset = null,
        .line = 1,
        .byte_column = 1,
    });

    inline for (.{
        .{
            .endian = TestEndian.little,
            .source = "<?xml version='1.0' encoding='UTF-16BE'?><r/>",
            .declared = "UTF-16BE",
        },
        .{
            .endian = TestEndian.big,
            .source = "<?xml version='1.0' encoding='UTF-16LE'?><r/>",
            .declared = "UTF-16LE",
        },
    }) |case| {
        const encoded = try encodeUtf16(
            std.testing.allocator,
            case.source,
            case.endian,
            true,
        );
        defer std.testing.allocator.free(encoded);
        const token = std.mem.indexOf(u8, case.source, case.declared).?;
        const offset = 2 + 2 * token;
        try expectNormalFailureSchedules(encoded, .{
            .category = error.InvalidEncoding,
            .code = .encoding_mismatch,
            .byte_offset = offset,
            .related_byte_offset = null,
            .line = 1,
            .byte_column = 2 * token + 1,
        });
    }

    const utf8_declared_utf16 = "<?xml version='1.0' encoding='UTF-16'?><r/>";
    const token = std.mem.indexOf(u8, utf8_declared_utf16, "UTF-16").?;
    try expectNormalFailureSchedules(utf8_declared_utf16, .{
        .category = error.InvalidEncoding,
        .code = .encoding_mismatch,
        .byte_offset = token,
        .related_byte_offset = null,
        .line = 1,
        .byte_column = token + 1,
    });
}

test "[failure] - [Reader decoder]: UTF-16 grammar diagnostics keep physical locations" {
    const source = "<r>\r\n<x></y></r>";
    const mismatch = std.mem.indexOf(u8, source, "y").?;
    const related = std.mem.indexOf(u8, source, "<x").?;
    inline for (.{ TestEndian.little, TestEndian.big }) |endian| {
        const encoded = try encodeUtf16(std.testing.allocator, source, endian, true);
        defer std.testing.allocator.free(encoded);
        try expectNormalFailureSchedules(encoded, .{
            .category = error.InvalidXml,
            .code = .mismatched_end_tag,
            .byte_offset = 2 + 2 * mismatch,
            .related_byte_offset = 2 + 2 * related,
            .line = 2,
            .byte_column = 11,
        });
    }
}

test "[integration] - [Reader]: namespace policy keeps one event type" {
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<p:root xmlns:p='urn:test'/>" },
        .{ .namespaces = .raw },
    );
    defer reader.deinit();

    while (try reader.next()) |event| switch (event.data) {
        .start_element => |element| {
            try std.testing.expectEqualStrings("p:root", element.name.raw);
            try std.testing.expectEqual(@as(?xml.ExpandedName, null), element.name.expanded);
            try std.testing.expectEqual(@as(usize, 0), element.namespace_declarations.len);
            try std.testing.expectEqualStrings(
                "urn:test",
                element.attributeRaw("xmlns:p").?.value,
            );
            return;
        },
        else => {},
    };
    return error.MissingStartElement;
}

test "[integration] - [Reader]: event values borrow until the next read begins" {
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<root id='7'><child/></root>" },
        .{},
    );
    defer reader.deinit();

    _ = try reader.next();
    const event = (try reader.next()).?;
    const element = event.data.start_element;
    const borrowed_name = element.name.raw;
    const borrowed_value = element.attribute(null, "id").?.value;
    try std.testing.expectEqual(@as(?xml.Diagnostic, null), reader.diagnostic());
    _ = reader.memoryUsage();
    try std.testing.expectEqualStrings("root", borrowed_name);
    try std.testing.expectEqualStrings("7", borrowed_value);

    var copied_name: [4]u8 = undefined;
    @memcpy(&copied_name, borrowed_name);
    _ = try reader.next();
    try std.testing.expectEqualStrings("root", &copied_name);
}

const NormalDiagnosticLog = struct {
    calls: usize = 0,
    code: ?xml.DiagnosticCode = null,
    reader: ?*xml.Reader = null,
    reset_error: ?xml.ResetError = null,

    fn report(context: ?*anyopaque, diagnostic: xml.Diagnostic) void {
        const self: *NormalDiagnosticLog = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.code = diagnostic.code;
        if (self.reader) |reader| {
            reader.reset(.{ .slice = "<replacement/>" }, .{}, .retain_capacity) catch |failure| {
                self.reset_error = failure;
            };
        }
    }
};

test "[integration] - [Reader]: DTD rejection is sticky and reports once" {
    var log: NormalDiagnosticLog = .{};
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<!DOCTYPE root><root/>" },
        .{
            .dtd = .reject,
            .diagnostic_sink = .{ .context = &log, .report_fn = NormalDiagnosticLog.report },
        },
    );
    defer reader.deinit();
    log.reader = &reader;

    _ = try reader.next();
    try std.testing.expectError(error.DtdForbidden, reader.next());
    try std.testing.expectError(error.DtdForbidden, reader.next());
    try std.testing.expectEqual(@as(usize, 1), log.calls);
    try std.testing.expectEqual(xml.DiagnosticCode.dtd_forbidden, log.code.?);
    try std.testing.expectEqual(error.InvalidState, log.reset_error.?);
    try std.testing.expectEqual(xml.DiagnosticCode.dtd_forbidden, reader.diagnostic().?.code);
}

const NormalFindingLog = struct {
    calls: usize = 0,
    code: ?xml.DiagnosticCode = null,
    action: xml.dtd.FindingAction = .continue_validation,

    fn report(
        context: ?*anyopaque,
        finding: xml.dtd.Finding,
    ) xml.dtd.FindingAction {
        const self: *NormalFindingLog = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.code = finding.code;
        return self.action;
    }
};

test "[integration] - [Reader]: DTD validation keeps one event type" {
    const input =
        "<!DOCTYPE root [<!ELEMENT root EMPTY>" ++
        "<!ATTLIST root needed CDATA #REQUIRED>]>" ++
        "<root/>";
    var log: NormalFindingLog = .{};
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = input },
        .{ .dtd = .{ .validate = .{
            .finding_sink = .{ .context = &log, .report_fn = NormalFindingLog.report },
        } } },
    );
    defer reader.deinit();

    var validity: ?xml.DtdValidity = null;
    while (try reader.next()) |event| switch (event.data) {
        .document_end => |result| validity = result.dtd_validity,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), log.calls);
    try std.testing.expectEqual(xml.DiagnosticCode.validity_required_attribute, log.code.?);
    try std.testing.expectEqual(xml.DtdValidity.invalid, validity.?);
}

test "[failure] - [Reader cancellation]: callback cancellation is sticky until reset" {
    const input =
        "<!DOCTYPE root [<!ELEMENT root EMPTY>" ++
        "<!ATTLIST root needed CDATA #REQUIRED>]>" ++
        "<root/>";
    var log: NormalFindingLog = .{ .action = .cancel };
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = input },
        .{ .dtd = .{ .validate = .{
            .finding_sink = .{ .context = &log, .report_fn = NormalFindingLog.report },
        } } },
    );
    defer reader.deinit();

    while (true) {
        const event = reader.next() catch |failure| {
            try std.testing.expectEqual(error.Cancelled, failure);
            break;
        };
        if (event == null) return error.ExpectedCancellation;
    }
    try std.testing.expectEqual(@as(usize, 1), log.calls);
    try std.testing.expectError(error.Cancelled, reader.next());

    try reader.reset(
        .{ .slice = "<root/>" },
        .{ .dtd = .reject },
        .retain_capacity,
    );
    while (try reader.next()) |_| {}
    try std.testing.expect(reader.diagnostic() == null);
}

test "[integration] - [Reader lifecycle]: reset replaces every parser state" {
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<unused/>" },
        .{},
    );
    defer reader.deinit();

    try reader.reset(.{ .slice = "<active>text</active>" }, .{}, .retain_capacity);
    _ = try reader.next();
    _ = try reader.next();
    _ = try reader.next();
    try reader.reset(.{ .slice = "<pending>text</pending>" }, .{}, .retain_capacity);
    try std.testing.expect((try reader.next()).?.data == .document_start);
    _ = try reader.next();
    _ = try reader.next();
    try std.testing.expect((try reader.next()).?.data.text.final_fragment);
    try reader.reset(
        .{ .slice = "<p:active xmlns:p='urn:test'/>" },
        .{ .namespaces = .raw, .dtd = .reject },
        .retain_capacity,
    );
    try std.testing.expect((try reader.next()).?.data == .document_start);
    while (try reader.next()) |_| {}

    try reader.reset(.{ .slice = "<complete/>" }, .{}, .retain_capacity);
    while (try reader.next()) |_| {}
    try std.testing.expect((try reader.next()) == null);

    try reader.reset(.{ .slice = "<failed>" }, .{}, .release_memory);
    while (true) {
        const event = reader.next() catch |failure| {
            try std.testing.expectEqual(error.InvalidXml, failure);
            break;
        };
        if (event == null) return error.ExpectedFailure;
    }
    try std.testing.expectError(error.InvalidXml, reader.next());
    try reader.reset(.{ .slice = "<recovered/>" }, .{ .dtd = .reject }, .retain_capacity);
    while (try reader.next()) |_| {}
    try std.testing.expect(reader.diagnostic() == null);
}

test "[failure] - [Reader reset]: invalid options preserve active state and borrows" {
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<root id='7'/>" },
        .{},
    );
    defer reader.deinit();

    _ = try reader.next();
    const event = (try reader.next()).?;
    const start = event.data.start_element;
    try std.testing.expectError(
        error.InvalidOptions,
        reader.reset(
            .{ .slice = "<replacement/>" },
            .{ .external = .resolve },
            .release_memory,
        ),
    );
    try std.testing.expectEqualStrings("root", start.name.raw);
    try std.testing.expectEqualStrings("7", start.attribute(null, "id").?.value);
    while (try reader.next()) |_| {}
}

test "[unit] - [Reader reset]: capacity policy is allocation free and exact" {
    const input = "<root first='one' second='two'><child/></root>";
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader = try xml.Reader.init(
        failing.allocator(),
        .{ .slice = input },
        .{ .dtd = .reject },
    );
    defer reader.deinit();

    while (try reader.next()) |_| {}
    try std.testing.expect(reader.memoryUsage().retained_capacity > 0);
    try reader.reset(.{ .slice = input }, .{ .dtd = .reject }, .retain_capacity);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    while (try reader.next()) |_| {}
    try std.testing.expect(!failing.has_induced_failure);

    var limited_options: xml.ReaderOptions = .{ .dtd = .reject };
    limited_options.limits.max_retained_bytes = 0;
    try reader.reset(.{ .slice = "<root/>" }, limited_options, .retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);

    try reader.reset(.{ .slice = "<root/>" }, .{ .dtd = .reject }, .release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
}

test "[unit] - [Reader reset]: engine selection does not allocate" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var reader = try xml.Reader.init(
        failing.allocator(),
        .{ .slice = "<root/>" },
        .{},
    );
    defer reader.deinit();

    try reader.reset(
        .{ .slice = "<root/>" },
        .{ .namespaces = .raw, .dtd = .{ .validate = .{} } },
        .release_memory,
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "[unit] - [Reader reset]: disabling DTD processing releases its storage" {
    const input =
        "<!DOCTYPE root [<!ELEMENT root (#PCDATA)><!ENTITY value 'text'>]>" ++
        "<root>&value;</root>";
    var reader = try xml.Reader.init(std.testing.allocator, .{ .slice = input }, .{});
    defer reader.deinit();
    while (try reader.next()) |_| {}
    try std.testing.expect(reader.memoryUsage().dtd_capacity > 0);

    try reader.reset(.{ .slice = "<root/>" }, .{ .dtd = .reject }, .retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().dtd_capacity);
}

test "[integration] - [Reader lifecycle]: early stop ignores unread input" {
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = "<root><broken" },
        .{},
    );
    defer reader.deinit();

    _ = try reader.next();
    const start = (try reader.next()).?.data.start_element;
    try std.testing.expectEqualStrings("root", start.name.raw);
    try reader.reset(.{ .slice = "<next/>" }, .{}, .retain_capacity);
    while (try reader.next()) |_| {}

    const stream_input = "<root><broken";
    var stream_buffer: [1]u8 = undefined;
    var source: std.testing.Reader = .init(
        &stream_buffer,
        &.{.{ .buffer = stream_input }},
    );
    source.artificial_limit = .limited(1);
    var stream_reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .stream = &source.interface },
        .{},
    );
    defer stream_reader.deinit();
    _ = try stream_reader.next();
    _ = try stream_reader.next();
    try std.testing.expect(source.next_offset < stream_input.len);
}

test "[integration] - [Reader lifecycle]: stream reset starts after the last event" {
    const input = "<one/><two/>";
    var input_buffer: [1]u8 = undefined;
    var source: std.testing.Reader = .init(
        &input_buffer,
        &.{.{ .buffer = input }},
    );
    source.artificial_limit = .limited(1);
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .stream = &source.interface },
        .{},
    );
    defer reader.deinit();

    _ = try reader.next();
    _ = try reader.next();
    const first_end = (try reader.next()).?.data.end_element;
    try std.testing.expectEqualStrings("one", first_end.name.raw);

    try reader.reset(.{ .stream = &source.interface }, .{}, .retain_capacity);
    _ = try reader.next();
    const second_start = (try reader.next()).?.data.start_element;
    try std.testing.expectEqualStrings("two", second_start.name.raw);
    while (try reader.next()) |_| {}
}

test "[failure] - [Reader source]: final input and read failure are sticky" {
    const expected = try normalFailure(.{ .slice = "<root" });
    var truncated_buffer: [2]u8 = undefined;
    var truncated_source: std.testing.Reader = .init(
        &truncated_buffer,
        &.{.{ .buffer = "<root" }},
    );
    truncated_source.artificial_limit = .limited(1);
    try std.testing.expectEqual(
        expected,
        try normalFailure(.{ .stream = &truncated_source.interface }),
    );

    var failed_buffer: [1]u8 = undefined;
    var failed_source = std.Io.Reader.failing;
    failed_source.buffer = &failed_buffer;
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .stream = &failed_source },
        .{},
    );
    defer reader.deinit();
    try std.testing.expectError(error.ReadFailed, reader.next());
    try std.testing.expectEqual(xml.DiagnosticCode.read_failed, reader.diagnostic().?.code);
    try std.testing.expectError(error.ReadFailed, reader.next());
}

test "[unit] - [Reader]: initialization validates options without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var reader = try xml.Reader.init(
        failing.allocator(),
        .{ .slice = "<root/>" },
        .{},
    );
    reader.deinit();
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);

    try std.testing.expectError(
        error.InvalidOptions,
        xml.Reader.init(
            std.testing.allocator,
            .{ .slice = "<root/>" },
            .{ .external = .resolve },
        ),
    );
}

test "[integration] - [Reader]: errors keep their public class and line policy" {
    const cases = .{
        .{ "<root>\xff</root>", error.InvalidEncoding, xml.DiagnosticCode.malformed_utf8 },
        .{
            "<?xml version='2.0'?><root/>",
            error.UnsupportedVersion,
            xml.DiagnosticCode.unsupported_version,
        },
    };
    inline for (cases) |case| {
        var reader = try xml.Reader.init(
            std.testing.allocator,
            .{ .slice = case[0] },
            .{ .track_lines = false },
        );
        defer reader.deinit();
        while (true) {
            const event = reader.next() catch |failure| {
                try std.testing.expectEqual(case[1], failure);
                break;
            };
            if (event == null) return error.ExpectedFailure;
        }
        const diagnostic = reader.diagnostic().?;
        try std.testing.expectEqual(case[2], diagnostic.code);
        try std.testing.expectEqual(@as(?u64, null), diagnostic.primary.line);
        try std.testing.expectEqual(@as(?u64, null), diagnostic.primary.byte_column);
    }
}

test "config - representative profiles: compile specialized public types" {
    inline for (.{
        xml.Configs.XML10_UTF8_NO_DTD_FAST,
        xml.Configs.XML10_UTF8_NO_DTD,
        xml.Configs.XML10_UTF8_NO_DTD_LOCATED,
        xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD,
        xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD_FAST,
        xml.Configs.XML10_NO_DTD,
        xml.Configs.XML10_NO_DTD_FAST,
        xml.Configs.XML10_NAMESPACES_NO_DTD,
        xml.Configs.XML10_NAMESPACES_NO_DTD_FAST,
        xml.Configs.XML10_NONVALIDATING,
        xml.Configs.XML10_NAMESPACES_NONVALIDATING,
        xml.Configs.XML10_VALIDATING,
        xml.Configs.XML10_NAMESPACES_VALIDATING_DETAILED,
        xml.Configs.XML11_NONVALIDATING,
        xml.Configs.XML11_NAMESPACES_NONVALIDATING,
        xml.Configs.XML11_VALIDATING,
        xml.Configs.XML11_NAMESPACES_VALIDATING,
    }) |config| {
        _ = xml.ReaderFor(config);
        _ = xml.EventFor(config);
        _ = xml.StepFor(config);
        _ = xml.OptionsFor(config);
        _ = xml.DiagnosticFor(config);
        _ = xml.NameFor(config);
        _ = xml.AttributeFor(config);
        _ = xml.ProfileSliceReader(config);
        _ = xml.ProfileIoReader(config);
    }
}

test "config - excluded capabilities: specialized types omit impossible fields" {
    const fast_config = xml.Configs.XML10_UTF8_NO_DTD_FAST;
    const full_config = xml.Configs.XML10_NONVALIDATING;

    try std.testing.expect(!@hasField(xml.EventFor(fast_config), "document_type"));
    try std.testing.expect(@hasField(xml.EventFor(full_config), "document_type"));
    try std.testing.expect(
        @sizeOf(xml.LocationFor(fast_config)) <
            @sizeOf(xml.LocationFor(xml.Configs.XML10_UTF8_NO_DTD)),
    );
}

test "[unit] - [XML version]: XML 1.1 profiles select declared document rules" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const cases = .{
        .{ "<root/>", xml.XmlVersion.xml10, "" },
        .{ "<?xml version='1.0'?><root/>", xml.XmlVersion.xml10, "1.0" },
        .{ "<?xml version='1.7'?><root/>", xml.XmlVersion.xml10, "1.7" },
        .{ "<?xml version='1.1'?><root/>", xml.XmlVersion.xml11, "1.1" },
    };
    inline for (cases) |case| {
        var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
        defer reader.deinit();
        try reader.feed(case[0], true);
        const event = (try reader.next()).event;
        switch (event) {
            .document_start => |document| {
                try std.testing.expectEqual(case[1], document.effective_version);
                if (case[2].len != 0) {
                    try std.testing.expectEqualStrings(case[2], document.declared_version.?);
                } else {
                    try std.testing.expect(document.declared_version == null);
                }
            },
            else => return error.UnexpectedEvent,
        }
    }
}

test "[unit] - [XML 1.1 normalization]: policy reports final verification state" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const normalized = "<?xml version='1.1'?><root>caf\xc3\xa9</root>";
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){ .status = .normalized, .issue = null },
        try normalizationOutcome(config, .{}, normalized, .whole),
    );

    var unchecked: xml.OptionsFor(config) = .{};
    unchecked.normalization = .unchecked;
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){ .status = .unchecked, .issue = null },
        try normalizationOutcome(config, unchecked, normalized, .whole),
    );
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){ .status = .unchecked, .issue = null },
        try normalizationOutcome(config, .{}, "<root/>", .whole),
    );

    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<?xml version='1.1'?><root>e\xcc\x81</root>", true);
    var text_bytes: [3]u8 = undefined;
    var text_len: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |value| {
                @memcpy(text_bytes[text_len..][0..value.bytes.len], value.bytes);
                text_len += value.bytes.len;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqualStrings("e\xcc\x81", text_bytes[0..text_len]);
    try std.testing.expectEqual(
        xml.ProfileNormalizationStatus.not_normalized,
        reader.normalizationResult().status,
    );
}

test "[property] - [XML 1.1 normalization]: source NFC is stable across schedules" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const input = "<?xml version='1.1'?><root>e\xcc\x81</root>";
    const offset = std.mem.indexOf(u8, input, "\xcc\x81").?;
    try expectNormalizationSchedules(input, .{
        .status = .not_normalized,
        .issue = .{
            .kind = .not_nfc,
            .location = .{
                .source_id = 0,
                .byte_offset = offset,
                .line = 1,
                .byte_column = offset + 1,
            },
        },
    });

    var strict: xml.OptionsFor(config) = .{};
    strict.normalization = .require;
    try expectProfileFailureSchedules(
        config,
        strict,
        input,
        error.NotNormalized,
        .not_fully_normalized,
        offset,
        null,
    );

    const multiline = "<?xml version='1.1'?>\n<!DOCTYPE r [<!--e\xcc\x81-->]><r/>";
    const multiline_offset = std.mem.indexOf(u8, multiline, "\xcc\x81").?;
    const expected_failure = NormalizationFailureOutcome{
        .events = 2,
        .byte_offset = multiline_offset,
        .line = 2,
        .byte_column = multiline_offset - std.mem.indexOf(u8, multiline, "<!DOCTYPE").? + 1,
    };
    try std.testing.expectEqual(
        expected_failure,
        try strictNormalizationFailure(multiline, multiline.len),
    );
    try std.testing.expectEqual(
        expected_failure,
        try strictNormalizationFailure(multiline, 1),
    );
}

test "[unit] - [XML 1.1 normalization]: canonical forms cover composition and ordering" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const cases = .{
        "<?xml version='1.1'?><root>\xe2\x84\xab</root>",
        "<?xml version='1.1'?><root>\xe1\x84\x80\xe1\x85\xa1</root>",
        "<?xml version='1.1'?><root>a\xcc\x95\xcc\x80</root>",
    };
    inline for (cases) |input| {
        const result = try normalizationOutcome(config, .{}, input, .whole);
        try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, result.status);
        try std.testing.expectEqual(xml.NormalizationIssueKind.not_nfc, result.issue.?.kind);
    }

    const normalized = "<?xml version='1.1'?><root>\xea\xb0\x80a\xcc\x95</root>";
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){ .status = .normalized, .issue = null },
        try normalizationOutcome(config, .{}, normalized, .whole),
    );
    try expectNormalizationSchedules(
        "<?xml version='1.1'?><root>x\xcc\x95</root>",
        .{ .status = .normalized, .issue = null },
    );
}

test "[unit] - [XML 1.1 normalization]: expanded references preserve construct rules" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const composing = "<?xml version='1.1'?><root>\xcc\x81x</root>";
    const composing_offset = std.mem.indexOf(u8, composing, "\xcc\x81").?;
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){
            .status = .not_normalized,
            .issue = .{
                .kind = .composing_start,
                .location = .{
                    .source_id = 0,
                    .byte_offset = composing_offset,
                    .line = 1,
                    .byte_column = composing_offset + 1,
                },
            },
        },
        try normalizationOutcome(config, .{}, composing, .whole),
    );

    const reference = "<?xml version='1.1'?><root>A&#x30A;</root>";
    const reference_offset = std.mem.indexOf(u8, reference, "&#x30A;").?;
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){
            .status = .not_normalized,
            .issue = .{
                .kind = .not_nfc,
                .location = .{
                    .source_id = 0,
                    .byte_offset = reference_offset,
                    .line = 1,
                    .byte_column = reference_offset + 1,
                },
            },
        },
        try normalizationOutcome(config, .{}, reference, .whole),
    );

    const attribute = "<?xml version='1.1'?><root a='A&#x30A;'/>";
    const attribute_offset = std.mem.indexOf(u8, attribute, "a=").?;
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){
            .status = .not_normalized,
            .issue = .{
                .kind = .not_nfc,
                .location = .{
                    .source_id = 0,
                    .byte_offset = attribute_offset,
                    .line = 1,
                    .byte_column = attribute_offset + 1,
                },
            },
        },
        try normalizationOutcome(config, .{}, attribute, .whole),
    );

    const cdata = "<?xml version='1.1'?><root><![CDATA[\xcc\x81x]]></root>";
    const cdata_offset = std.mem.indexOf(u8, cdata, "\xcc\x81").?;
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){
            .status = .not_normalized,
            .issue = .{
                .kind = .composing_start,
                .location = .{
                    .source_id = 0,
                    .byte_offset = cdata_offset,
                    .line = 1,
                    .byte_column = cdata_offset + 1,
                },
            },
        },
        try normalizationOutcome(config, .{}, cdata, .whole),
    );

    const name = "<?xml version='1.1'?><\xe1\x85\xa1/>";
    const name_offset = std.mem.indexOf(u8, name, "\xe1\x85\xa1").?;
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){
            .status = .not_normalized,
            .issue = .{
                .kind = .composing_start,
                .location = .{
                    .source_id = 0,
                    .byte_offset = name_offset,
                    .line = 1,
                    .byte_column = name_offset + 1,
                },
            },
        },
        try normalizationOutcome(config, .{}, name, .whole),
    );
}

test "[property] - [XML 1.1 normalization]: UTF-16 source findings retain byte offsets" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const utf8 = "<?xml version='1.1'?><root>e\xcc\x81</root>";
    const encoded = try encodeUtf16(std.testing.allocator, utf8, .little, true);
    defer std.testing.allocator.free(encoded);
    const expected_offset = 2 + 2 * std.mem.indexOf(u8, utf8, "\xcc\x81").?;
    const result = try normalizationOutcome(config, .{}, encoded, .{ .fixed = 1 });
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, result.status);
    try std.testing.expectEqual(xml.NormalizationIssueKind.not_nfc, result.issue.?.kind);
    try std.testing.expectEqual(@as(u64, expected_offset), result.issue.?.location.byte_offset);
}

test "[unit] - [XML 1.1 normalization]: reset clears verification state" {
    const config = xml.Configs.XML11_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<?xml version='1.1'?><root>e\xcc\x81</root>", true);
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, reader.normalizationResult().status);

    try reader.reset(.retain_capacity);
    try reader.feed("<?xml version='1.1'?><root/>", true);
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.normalized, reader.normalizationResult().status);
}

test "[unit] - [XML 1.1 normalization]: unknown properties remain explicit" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const input = "<?xml version='1.1'?><root>\xcd\xb8</root>";
    const offset = std.mem.indexOf(u8, input, "\xcd\xb8").?;
    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){
            .status = .indeterminate,
            .issue = .{
                .kind = .unknown_character,
                .location = .{
                    .source_id = 0,
                    .byte_offset = offset,
                    .line = 1,
                    .byte_column = offset + 1,
                },
            },
        },
        try normalizationOutcome(config, .{}, input, .whole),
    );

    var strict: xml.OptionsFor(config) = .{};
    strict.normalization = .require;
    try expectProfileFailureSchedules(
        config,
        strict,
        input,
        error.NotNormalized,
        .normalization_properties_unknown,
        offset,
        null,
    );

    try std.testing.expectEqual(
        xml.NormalizationResultFor(config){ .status = .normalized, .issue = null },
        try normalizationOutcome(
            config,
            .{},
            "<?xml version='1.1'?><root>\xef\xb7\x90</root>",
            .whole,
        ),
    );
}

test "[integration] - [XML 1.1 normalization]: DTD values and Nmtokens are verified" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const entity = "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e '&#x301;'>]><r/>";
    const entity_result = try normalizationOutcome(config, .{}, entity, .whole);
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, entity_result.status);
    try std.testing.expectEqual(xml.NormalizationIssueKind.composing_start, entity_result.issue.?.kind);

    const token = "<?xml version='1.1'?><!DOCTYPE r [" ++
        "<!ATTLIST r n NMTOKEN #IMPLIED>]><r n='\xcc\x81x'/>";
    const token_result = try normalizationOutcome(config, .{}, token, .whole);
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, token_result.status);
    try std.testing.expectEqual(xml.NormalizationIssueKind.composing_start, token_result.issue.?.kind);

    const boundary = "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e 'x'>]>" ++
        "<r>&e;\xcc\x81</r>";
    const boundary_result = try normalizationOutcome(config, .{}, boundary, .{ .fixed = 1 });
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, boundary_result.status);
    try std.testing.expectEqual(
        xml.NormalizationIssueKind.composing_start,
        boundary_result.issue.?.kind,
    );

    const processing_instruction =
        "<?xml version='1.1'?><!DOCTYPE r [<?\xe1\x85\xa1?>]><r/>";
    const processing_instruction_result = try normalizationOutcome(
        config,
        .{},
        processing_instruction,
        .whole,
    );
    try std.testing.expectEqual(
        xml.ProfileNormalizationStatus.not_normalized,
        processing_instruction_result.status,
    );
    try std.testing.expectEqual(
        xml.NormalizationIssueKind.composing_start,
        processing_instruction_result.issue.?.kind,
    );
    try std.testing.expectEqual(
        @as(u64, std.mem.indexOf(u8, processing_instruction, "\xe1\x85\xa1").?),
        processing_instruction_result.issue.?.location.byte_offset,
    );
}

test "[integration] - [XML 1.1 characters]: references admit restricted controls" {
    const config = xml.Configs.XML11_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<?xml version='1.1'?><root>&#x1;&#x7f;</root>", true);

    var text: [2]u8 = undefined;
    var text_len: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |value| {
                @memcpy(text[text_len..][0..value.bytes.len], value.bytes);
                text_len += value.bytes.len;
            },
            else => {},
        },
        .done => break,
        .need_input => unreachable,
    };
    try std.testing.expectEqualSlices(u8, &.{ 0x1, 0x7f }, text[0..text_len]);

    var literal = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer literal.deinit();
    try literal.feed("<?xml version='1.1'?><root>\x01</root>", true);
    while (true) switch (literal.next() catch |err| {
        try std.testing.expectEqual(error.InvalidXml, err);
        try std.testing.expectEqual(
            xml.DiagnosticCode.forbidden_character,
            literal.diagnostic().?.code,
        );
        break;
    }) {
        .event => {},
        .done => return error.ExpectedFailure,
        .need_input => unreachable,
    };
}

test "[property] - [XML 1.1 line endings]: semantic values agree across schedules" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const input =
        "<?xml version='1.1'?><root a='A\xc2\x85B\xe2\x80\xa8C\r\xc2\x85D'>" ++
        "T\xc2\x85U\xe2\x80\xa8V\r\xc2\x85W" ++
        "<!--C\xc2\x85D--><?p I\xe2\x80\xa8J?><![CDATA[K\xc2\x85L]]>" ++
        "</root>";
    const parts = [_][]const u8{input};
    const whole = try parseParts(config, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqualStrings(
        "A B C D",
        whole.attribute_event_bytes[3..][0..7],
    );
    try std.testing.expectEqualStrings("T\nU\nV\nWK\nL", whole.text_bytes[0..whole.text_bytes_len]);
    try std.testing.expectEqualStrings("C\nD", whole.comment_bytes[0..whole.comment_bytes_len]);
    try std.testing.expectEqualStrings(
        "p\x00I\nJ\xff",
        whole.processing_instruction_bytes[0..whole.processing_instruction_bytes_len],
    );
    try std.testing.expectEqualStrings("K\nL", whole.cdata_bytes[0..whole.cdata_bytes_len]);
    try expectSummarySchedulesWithOptions(config, .{}, input, whole);
}

test "[property] - [XML 1.1 UTF-16]: line endings agree across byte schedules" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const encoded = try encodeUtf16(
        std.testing.allocator,
        "<?xml version='1.1'?><root>A\xc2\x85B\xe2\x80\xa8C\r\xc2\x85D</root>",
        .little,
        true,
    );
    defer std.testing.allocator.free(encoded);
    const parts = [_][]const u8{encoded};
    const whole = try parseParts(config, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqual(.utf16_le, whole.source_encoding);
    try std.testing.expectEqualStrings("A\nB\nC\nD", whole.text_bytes[0..whole.text_bytes_len]);
    try expectSummarySchedulesWithOptions(config, .{}, encoded, whole);
}

test "[unit] - [XML 1.1 reset]: pending line scalar does not cross documents" {
    const config = xml.Configs.XML11_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<?xml version='1.1'?><root>\xc2", false);
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => break,
        .done => return error.UnexpectedDone,
    };

    try reader.reset(.retain_capacity);
    try reader.feed("<?xml version='1.1'?><root>A\xc2\x85B</root>", true);
    var text: [3]u8 = undefined;
    var text_len: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |value| {
                @memcpy(text[text_len..][0..value.bytes.len], value.bytes);
                text_len += value.bytes.len;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqualStrings("A\nB", text[0..text_len]);
}

test "[integration] - [XML 1.1 DTD]: declaration references use document character rules" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const input =
        "<?xml version='1.1'?><!DOCTYPE r [" ++
        "<!ENTITY e '&#x1;&#xD;&#x85;&#x2028;'>]><r>&e;</r>";
    const parts = [_][]const u8{input};
    const summary = try parseParts(config, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqualSlices(
        u8,
        "\x01\r\xc2\x85\xe2\x80\xa8",
        summary.text_bytes[0..summary.text_bytes_len],
    );
}

test "[integration] - [XML 1.1 validation]: internal replacement whitespace remains ignorable" {
    const config = xml.Configs.XML11_VALIDATING;
    const declarations =
        "<!ENTITY data '&#x9;&#xA;&#xD;'>" ++
        "<!ELEMENT root (child)><!ELEMENT child EMPTY>";
    const valid = "<?xml version='1.1'?><!DOCTYPE root [" ++ declarations ++
        "]><root>&data;<child/></root>";
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(valid, true);
    var saw_ignorable = false;
    var status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |text| saw_ignorable = saw_ignorable or text.ignorable_whitespace,
            .document_end => |end| status = end.validation,
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expect(saw_ignorable);
    try std.testing.expectEqual(xml.ProfileValidationStatus.valid, status.?);

    const invalid = "<?xml version='1.1'?><!DOCTYPE root [" ++ declarations ++
        "]><root>&#x20;<child/></root>";
    const parts = [_][]const u8{invalid};
    try expectProfileFailureParts(
        config,
        .{},
        &parts,
        error.NotValid,
        .validity_element_content,
        std.mem.indexOf(u8, invalid, "&#x20;").?,
        null,
    );
}

test "[integration] - [XML 1.1 namespaces]: prefixed bindings can be undeclared" {
    const config = xml.Configs.XML11_NAMESPACES_NONVALIDATING;
    const valid = "<?xml version='1.1'?><r xmlns:p='urn:p'><a xmlns:p=''/></r>";
    var valid_reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer valid_reader.deinit();
    try valid_reader.feed(valid, true);
    while (true) switch (try valid_reader.next()) {
        .event => {},
        .done => break,
        .need_input => unreachable,
    };

    const cases = .{
        "<?xml version='1.0'?><r xmlns:p='urn:p'><a xmlns:p=''/></r>",
        "<?xml version='1.1'?><r xmlns:p='urn:p'><a xmlns:p=''><p:b/></a></r>",
    };
    inline for (cases) |input| {
        var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
        defer reader.deinit();
        try reader.feed(input, true);
        while (true) switch (reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        }) {
            .event => {},
            .done => return error.ExpectedFailure,
            .need_input => unreachable,
        };
    }
}

test "[integration] - [DTD validation]: accepts declared sequence and attributes" {
    const config = xml.Configs.XML10_VALIDATING;
    const input = "<!DOCTYPE root [" ++
        "<!ELEMENT root (item+)>" ++
        "<!ELEMENT item (#PCDATA)>" ++
        "<!ATTLIST item id ID #REQUIRED refs IDREFS #IMPLIED kind (a|b) #FIXED 'a'>" ++
        "]><root><item id='one'/><item id='two' refs='one' kind='a'>text</item></root>";
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);
    var status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_end => |document| status = document.validation,
            else => {},
        },
        .done => break,
        .need_input => unreachable,
    };
    try std.testing.expectEqual(xml.ProfileValidationStatus.valid, status.?);
    try std.testing.expect(reader.diagnostic() == null);
}

test "[failure] - [DTD validation]: stop-first reports content mismatch" {
    const config = xml.Configs.XML10_VALIDATING;
    const input = "<!DOCTYPE root [<!ELEMENT root (a,b)><!ELEMENT a EMPTY><!ELEMENT b EMPTY>]>" ++
        "<root><b/></root>";
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.NotValid, err);
            break;
        };
    }
    try std.testing.expectEqual(
        xml.DiagnosticCode.validity_element_content,
        reader.diagnostic().?.code,
    );
}

test "[integration] - [DTD validation]: collection reaches explicit invalid result" {
    const config = xml.Configs.XML10_VALIDATING;
    const input = "<!DOCTYPE root [<!ELEMENT root EMPTY><!ATTLIST root needed CDATA #REQUIRED>]>" ++
        "<root><child/></root>";
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{
        .validation = .{ .collect_validity_errors = true },
    });
    defer reader.deinit();
    try reader.feed(input, true);
    var status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_end => |document| status = document.validation,
            else => {},
        },
        .done => break,
        .need_input => unreachable,
    };
    try std.testing.expectEqual(xml.ProfileValidationStatus.invalid, status.?);
    try std.testing.expectEqual(
        xml.DiagnosticCode.validity_required_attribute,
        reader.diagnostic().?.code,
    );
}

const ValidityLog = struct {
    codes: [8]xml.DiagnosticCode = @splat(.empty_document),
    len: usize = 0,
    cancel_after: ?usize = null,

    fn sink(self: *@This()) xml.ValiditySinkFor(xml.Configs.XML10_VALIDATING) {
        return .{ .context = self, .reportFn = report };
    }

    fn report(context: ?*anyopaque, diagnostic: xml.DiagnosticFor(xml.Configs.XML10_VALIDATING)) xml.ProfileValidityAction {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.len < self.codes.len) self.codes[self.len] = diagnostic.code;
        self.len += 1;
        if (self.cancel_after != null and self.len == self.cancel_after.?) return .cancel;
        return .continue_validation;
    }
};

test "[integration] - [validity collection]: first error agrees and independent checks continue" {
    const config = xml.Configs.XML10_VALIDATING;
    const input = "<!DOCTYPE root [<!ELEMENT root EMPTY><!ATTLIST root needed CDATA #REQUIRED>]>" ++
        "<root><child/></root>";
    var log: ValidityLog = .{};
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{
        .validation = .{
            .collect_validity_errors = true,
            .sink = log.sink(),
        },
    });
    defer reader.deinit();
    try reader.feed(input, true);
    var status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_end => |document| status = document.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };
    try std.testing.expectEqual(xml.ProfileValidationStatus.invalid, status.?);
    try std.testing.expect(log.len >= 2);
    try std.testing.expectEqual(xml.DiagnosticCode.validity_required_attribute, log.codes[0]);
    try std.testing.expectEqual(log.codes[0], reader.diagnostic().?.code);

    var stop = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer stop.deinit();
    try stop.feed(input, true);
    while (true) {
        _ = stop.next() catch |err| {
            try std.testing.expectEqual(error.NotValid, err);
            break;
        };
    }
    try std.testing.expectEqual(log.codes[0], stop.diagnostic().?.code);
}

test "[edge] - [validity collection]: diagnostic ceiling produces incomplete result" {
    const config = xml.Configs.XML10_VALIDATING;
    var log: ValidityLog = .{};
    var options: xml.OptionsFor(config) = .{};
    options.validation.collect_validity_errors = true;
    options.validation.sink = log.sink();
    options.validation.limits.max_errors = 1;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [<!ELEMENT root EMPTY><!ATTLIST root first CDATA #REQUIRED second CDATA #REQUIRED>]><root/>",
        true,
    );
    var status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_end => |document| status = document.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };
    try std.testing.expectEqual(@as(usize, 1), log.len);
    try std.testing.expectEqual(xml.ProfileValidationStatus.incomplete, status.?);
}

test "[failure] - [validity sink]: cancellation is sticky" {
    const config = xml.Configs.XML10_VALIDATING;
    var log: ValidityLog = .{ .cancel_after = 1 };
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{
        .validation = .{
            .collect_validity_errors = true,
            .sink = log.sink(),
        },
    });
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root [<!ELEMENT root EMPTY>]><other/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.Cancelled, err);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), log.len);
    try std.testing.expectError(error.Cancelled, reader.next());
}

fn validationAllocationAttempt(allocator: std.mem.Allocator) !void {
    const config = xml.Configs.XML10_VALIDATING;
    var reader = try xml.ReaderFor(config).init(allocator, .{});
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [" ++
            "<!ELEMENT root (item+)><!ELEMENT item (#PCDATA)>" ++
            "<!ATTLIST item id ID #REQUIRED refs IDREFS #IMPLIED>" ++
            "]><root><item id='a'/><item id='b' refs='a'>text</item></root>",
        true,
    );
    while (true) switch (try reader.next()) {
        .event => {},
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };
}

test "[failure] - [validation storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        validationAllocationAttempt,
        .{},
    );
}

test "[unit] - [validation storage]: retained reset clears identity state and reuses capacity" {
    const config = xml.Configs.XML10_VALIDATING;
    const input = "<!DOCTYPE root [<!ELEMENT root (item+)><!ELEMENT item EMPTY>" ++
        "<!ATTLIST item id ID #REQUIRED ref IDREF #IMPLIED>]>" ++
        "<root><item id='one'/><item id='two' ref='one'/></root>";
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();

    try reader.feed(input, true);
    while (true) switch (try reader.next()) {
        .event => {},
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };
    const retained = reader.memoryUsage().retained_capacity;
    try std.testing.expectEqual(@as(usize, 2), reader.memoryUsage().id_count);
    try std.testing.expectEqual(@as(usize, 1), reader.memoryUsage().idref_count);
    try std.testing.expect(reader.memoryUsage().id_index_capacity > 0);

    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().id_count);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().idref_count);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().identity_bytes);
    try std.testing.expectEqual(retained, reader.memoryUsage().retained_capacity);
    try reader.feed(input, true);
    while (true) switch (try reader.next()) {
        .event => {},
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };
    try std.testing.expectEqual(@as(usize, 2), reader.memoryUsage().id_count);
    try std.testing.expectEqual(@as(usize, 1), reader.memoryUsage().idref_count);
    try std.testing.expect(reader.memoryUsage().retained_capacity >= retained);

    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
}

test "[integration] - [internal DTD]: applies defaults normalization and entity replacement" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const Reader = xml.ReaderFor(config);
    const input = "<!DOCTYPE root [<!ELEMENT root (#PCDATA)>" ++
        "<!ATTLIST root mode NMTOKENS '  one   two  '>" ++
        "<!ENTITY hello 'Hello'>]><root>&hello;</root>";
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);

    var saw_doctype = false;
    var saw_start = false;
    var text: [16]u8 = undefined;
    var text_len: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_type => |doctype| {
                saw_doctype = true;
                try std.testing.expectEqualStrings("root", doctype.root_name);
            },
            .start_element => |start| {
                saw_start = true;
                try std.testing.expectEqual(@as(usize, 1), start.attributes.len);
                try std.testing.expectEqualStrings("mode", start.attributes[0].name.raw);
                try std.testing.expectEqualStrings("one two", start.attributes[0].value);
                try std.testing.expect(!start.attributes[0].specified);
            },
            .text => |fragment| {
                @memcpy(text[text_len..][0..fragment.bytes.len], fragment.bytes);
                text_len += fragment.bytes.len;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expect(saw_doctype);
    try std.testing.expect(saw_start);
    try std.testing.expectEqualStrings("Hello", text[0..text_len]);
    try std.testing.expect(reader.memoryUsage().dtd_capacity > 0);
}

test "[integration] - [document type event]: header precedes internal subset input" {
    const config = xml.Configs.XML10_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root PUBLIC 'public-id' 'system-id' [", false);

    var saw_doctype = false;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_type => |doctype| {
                saw_doctype = true;
                try std.testing.expectEqualStrings("root", doctype.root_name);
                try std.testing.expectEqualStrings("public-id", doctype.public_id.?);
                try std.testing.expectEqualStrings("system-id", doctype.system_id.?);
            },
            else => {},
        },
        .need_input => break,
        .done => return error.UnexpectedDone,
    };
    try std.testing.expect(saw_doctype);

    try reader.feed("<!ELEMENT root EMPTY>]><root/>", true);
    while (true) switch (reader.next() catch |err| {
        try std.testing.expectEqual(error.UnsupportedFeature, err);
        try std.testing.expectEqual(
            xml.DiagnosticCode.external_resource_forbidden,
            reader.diagnostic().?.code,
        );
        break;
    }) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
}

test "[integration] - [document type event]: default policy reports and skips external subset" {
    const config = xml.Configs.XML10_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);

    var saw_doctype = false;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_type => |doctype| {
                saw_doctype = true;
                try std.testing.expectEqualStrings("root", doctype.root_name);
                try std.testing.expectEqualStrings("external.dtd", doctype.system_id.?);
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expect(saw_doctype);
    try std.testing.expectEqual(@as(?xml.DiagnosticFor(config), null), reader.diagnostic());
}

test "[integration] - [internal DTD namespaces]: default declaration precedes expansion" {
    const config = xml.Configs.XML10_NAMESPACES_NONVALIDATING;
    const Reader = xml.ReaderFor(config);
    const input = "<!DOCTYPE p:root [<!ELEMENT p:root EMPTY>" ++
        "<!ATTLIST p:root xmlns:p CDATA 'urn:defaulted'>]><p:root/>";
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);
    var saw_start = false;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| {
                saw_start = true;
                try std.testing.expectEqualStrings("urn:defaulted", start.name.namespace_uri.?);
                try std.testing.expectEqual(@as(usize, 1), start.namespace_declarations.len);
                try std.testing.expectEqual(@as(usize, 0), start.attributes.len);
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expect(saw_start);
}

test "[integration] - [internal DTD chunking]: one-byte input preserves declaration effects" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const Reader = xml.ReaderFor(config);
    const input = "<!DOCTYPE root [<!ELEMENT root (child)>" ++
        "<!ELEMENT child (#PCDATA)><!ENTITY value '<child>text</child>'>]><root>&value;</root>";
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    var offset: usize = 0;
    var starts: usize = 0;
    var ends: usize = 0;
    var text_bytes: usize = 0;
    while (true) {
        if (reader.lifecycle == .ready or reader.lifecycle == .needs_input) {
            if (offset == input.len) return error.UnexpectedNeedInput;
            try reader.feed(input[offset .. offset + 1], offset + 1 == input.len);
            offset += 1;
        }
        switch (try reader.next()) {
            .event => |event| switch (event) {
                .start_element => starts += 1,
                .end_element => ends += 1,
                .text => |fragment| text_bytes += fragment.bytes.len,
                else => {},
            },
            .need_input => {},
            .done => break,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), starts);
    try std.testing.expectEqual(@as(usize, 2), ends);
    try std.testing.expectEqual(@as(usize, 4), text_bytes);
}

test "[property] - [internal DTD chunking]: schedules preserve raw and namespace semantics" {
    const input = "<?xml version='1.0'?><!DOCTYPE p:root [" ++
        "<!ENTITY % declarations '<!ELEMENT p:root (#PCDATA)>'>%declarations;" ++
        "<!ENTITY inner 'in'><!ENTITY outer '&inner;side'>" ++
        "<!ATTLIST p:root xmlns:p CDATA 'urn:p' words NMTOKENS ' one   two '>]>" ++
        "<p:root>&outer;</p:root>";
    inline for (.{
        xml.Configs.XML10_NONVALIDATING,
        xml.Configs.XML10_NAMESPACES_NONVALIDATING,
    }) |config| {
        const whole = try dtdOutcome(config, input, .whole);
        for (1..input.len) |split| {
            try std.testing.expectEqual(whole, try dtdOutcome(config, input, .{ .split = split }));
        }
        try std.testing.expectEqual(whole, try dtdOutcome(config, input, .{ .fixed = 7 }));
        for (0..16) |seed| {
            try std.testing.expectEqual(whole, try dtdOutcome(config, input, .{ .random = seed + 1 }));
        }
    }
}

test "[property] - [validating chunking]: schedules preserve events and final validity" {
    const input = "<!DOCTYPE root [<!ELEMENT root (item+)><!ELEMENT item (#PCDATA)>" ++
        "<!ATTLIST item id ID #REQUIRED ref IDREF #IMPLIED>]>" ++
        "<root><item id='one'/><item id='two' ref='one'>text</item></root>";
    inline for (.{
        xml.Configs.XML10_VALIDATING,
        xml.Configs.XML10_NAMESPACES_VALIDATING,
    }) |config| {
        const whole = try dtdOutcome(config, input, .whole);
        try std.testing.expectEqual(xml.ProfileValidationStatus.valid, whole.validation.?);
        for (1..input.len) |split| {
            try std.testing.expectEqual(whole, try dtdOutcome(config, input, .{ .split = split }));
        }
        try std.testing.expectEqual(whole, try dtdOutcome(config, input, .{ .fixed = 7 }));
        for (0..8) |seed| {
            try std.testing.expectEqual(whole, try dtdOutcome(config, input, .{ .random = seed + 1 }));
        }
    }
}

test "[failure] - [internal entities]: recursion and expansion limits fail" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const Reader = xml.ReaderFor(config);
    {
        var reader = try Reader.init(std.testing.allocator, .{});
        defer reader.deinit();
        try reader.feed(
            "<!DOCTYPE root [<!ELEMENT root (#PCDATA)>" ++
                "<!ENTITY a '&b;'><!ENTITY b '&a;'>]><root>&a;</root>",
            true,
        );
        while (reader.next()) |step| {
            if (step == .done) return error.ExpectedRecursiveEntity;
        } else |err| try std.testing.expectEqual(error.InvalidXml, err);
        try std.testing.expectEqual(xml.DiagnosticCode.recursive_entity, reader.diagnostic().?.code);
    }
    {
        var reader = try Reader.init(std.testing.allocator, .{
            .dtd_limits = .{ .max_expanded_bytes = 3 },
        });
        defer reader.deinit();
        try reader.feed(
            "<!DOCTYPE root [<!ELEMENT root (#PCDATA)><!ENTITY a 'four'>]>" ++
                "<root>&a;</root>",
            true,
        );
        while (reader.next()) |step| {
            if (step == .done) return error.ExpectedExpansionLimit;
        } else |err| try std.testing.expectEqual(error.LimitExceeded, err);
        try std.testing.expectEqual(
            xml.DiagnosticCode.entity_expansion_limit,
            reader.diagnostic().?.code,
        );
    }
}

test "[edge] - [entity expansion ratio]: accepts the boundary and rejects one byte over" {
    const config = xml.Configs.XML10_NONVALIDATING;
    inline for (.{
        .{ "123456789", false },
        .{ "1234567890", true },
    }) |case| {
        var options: xml.OptionsFor(config) = .{};
        options.dtd_limits.max_expanded_bytes = 100;
        options.dtd_limits.max_expansion_ratio = 3;
        options.dtd_limits.expansion_ratio_minimum_bytes = 0;
        var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
        defer reader.deinit();
        const input = try std.mem.concat(std.testing.allocator, u8, &.{
            "<!DOCTYPE root [<!ENTITY a '",
            case[0],
            "'>]><root>&a;</root>",
        });
        defer std.testing.allocator.free(input);
        try reader.feed(input, true);
        var rejected = false;
        while (reader.next()) |step| {
            if (step == .done) break;
        } else |err| {
            try std.testing.expect(case[1]);
            try std.testing.expectEqual(error.LimitExceeded, err);
            try std.testing.expectEqual(
                xml.DiagnosticCode.entity_expansion_ratio_limit,
                reader.diagnostic().?.code,
            );
            rejected = true;
        }
        try std.testing.expectEqual(case[1], rejected);
    }
}

test "[failure] - [DTD declaration limit]: rejects before declaration publication" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const input = "<!DOCTYPE root [<!ELEMENT root EMPTY>]><root/>";
    var options: xml.OptionsFor(config) = .{};
    options.dtd_limits.max_declaration_bytes = "<!ELEMENT root EMPTY>".len - 1;

    try expectProfileFailureSchedules(
        config,
        options,
        input,
        error.LimitExceeded,
        .dtd_declaration_bytes_limit,
        @intCast(std.mem.indexOf(u8, input, "<!ELEMENT").?),
        null,
    );
}

test "[failure] - [predefined entities]: invalid declarations are fatal" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const input = "<!DOCTYPE root [<!ENTITY lt '&#60;'>]><root/>";

    try expectProfileFailureSchedules(
        config,
        .{},
        input,
        error.InvalidDtd,
        .malformed_entity_declaration,
        @intCast(std.mem.indexOfScalar(u8, input, '>').?),
        null,
    );
}

test "[property] - [DTD diagnostics]: malformed grammar location is schedule invariant" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const input = "<!DOCTYPE root [<!ELEMENT root (a|)>]><root/>";
    try expectProfileFailureSchedules(
        config,
        .{},
        input,
        error.InvalidDtd,
        .malformed_element_declaration,
        @intCast(std.mem.indexOfScalar(u8, input, ')').?),
        null,
    );
}

test "[property] - [DTD diagnostics]: declaration value locations are schedule invariant" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const attribute_input =
        "<!DOCTYPE root [<!ATTLIST root mode CDATA '&#x110000;'>]><root/>";
    try expectProfileFailureSchedules(
        config,
        .{},
        attribute_input,
        error.InvalidDtd,
        .malformed_attribute_list_declaration,
        @intCast(std.mem.indexOf(u8, attribute_input, "&#x110000;").?),
        null,
    );

    const notation_input =
        "<!DOCTYPE root [<!NOTATION image SYSTEM>]><root/>";
    try expectProfileFailureSchedules(
        config,
        .{},
        notation_input,
        error.InvalidDtd,
        .malformed_notation_declaration,
        @intCast(std.mem.indexOf(u8, notation_input, ">]").?),
        null,
    );
}

test "[failure] - [DTD replacement bytes limit]: reports the rejected value byte" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const input = "<!DOCTYPE root [<!ENTITY value 'ab'>]><root/>";
    var options: xml.OptionsFor(config) = .{};
    options.dtd_limits.max_entity_replacement_bytes = 1;
    try expectProfileFailureSchedules(
        config,
        options,
        input,
        error.LimitExceeded,
        .dtd_replacement_bytes_limit,
        @intCast(std.mem.indexOf(u8, input, "ab").? + 1),
        null,
    );
}

test "[failure] - [DTD storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationDtdParse,
        .{},
    );
}

test "[unit] - [DTD reset]: declarations and active entity state never cross documents" {
    const config = xml.Configs.XML10_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [<!ENTITY value 'text'>]><root>&value;</root>",
        true,
    );
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    const retained = reader.memoryUsage().dtd_capacity;
    try std.testing.expect(retained > 0);

    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_count);
    try reader.feed("<root>&value;</root>", true);
    while (reader.next()) |step| {
        if (step == .done) return error.ExpectedUndeclaredEntity;
    } else |err| try std.testing.expectEqual(error.InvalidXml, err);
    try std.testing.expectEqual(xml.DiagnosticCode.undeclared_entity, reader.diagnostic().?.code);

    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().dtd_capacity);
}

test "[integration] - [detailed DTD events]: declarations and entity boundaries retain order" {
    const config: xml.Config = .{
        .profile = .xml10_nonvalidating,
        .report = .detailed,
    };
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [<!--dtd--><?inside data?>" ++
            "<!ELEMENT root (#PCDATA)><!ATTLIST root a CDATA #IMPLIED>" ++
            "<!ENTITY value 'text'><!NOTATION n PUBLIC 'public'>" ++
            "<!ENTITY image SYSTEM 'image.bin' NDATA n>]><root>&value;</root>",
        true,
    );
    var declarations: usize = 0;
    var entity_starts: usize = 0;
    var entity_ends: usize = 0;
    var notation_seen = false;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .element_declaration, .attribute_list_declaration, .parsed_entity_declaration => {
                declarations += 1;
            },
            .notation_declaration => |notation| {
                notation_seen = true;
                try std.testing.expectEqualStrings("public", notation.public_id.?);
            },
            .unparsed_entity_declaration => |entity| {
                try std.testing.expectEqualStrings("n", entity.notation_name);
                try std.testing.expectEqualStrings("image.bin", entity.system_id.?);
            },
            .entity_start => |entity| {
                entity_starts += 1;
                try std.testing.expectEqualStrings("value", entity.name);
            },
            .entity_end => |entity| {
                entity_ends += 1;
                try std.testing.expectEqualStrings("value", entity.name);
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 3), declarations);
    try std.testing.expectEqual(@as(usize, 1), entity_starts);
    try std.testing.expectEqual(@as(usize, 1), entity_ends);
    try std.testing.expect(notation_seen);
}

test "[integration] - [standalone DTD effects]: undeclared entity exception requires non-standalone input" {
    const config = xml.Configs.XML10_NONVALIDATING;
    const body = "<!DOCTYPE root [<!ENTITY % marker '<!ELEMENT root ANY>'>%marker;]>" ++
        "<root>&undeclared;</root>";
    inline for (.{
        .{ "<?xml version='1.0'?>", false },
        .{ "<?xml version='1.0' standalone='no'?>", false },
        .{ "<?xml version='1.0' standalone='yes'?>", true },
    }) |case| {
        var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
        defer reader.deinit();
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ case[0], body });
        defer std.testing.allocator.free(input);
        try reader.feed(input, true);
        var rejected = false;
        while (reader.next()) |step| {
            if (step == .done) break;
        } else |err| {
            try std.testing.expect(case[1]);
            try std.testing.expectEqual(error.InvalidXml, err);
            rejected = true;
        }
        try std.testing.expectEqual(case[1], rejected);
    }
}

test "[integration] - [DTD attribute defaults]: nested entities normalize before publication" {
    const config = xml.Configs.XML10_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [<!ENTITY % marker 'literal'><!ENTITY inner 'one  two'>" ++
            "<!ENTITY outer '&inner; three'><!ATTLIST root words NMTOKENS '&outer;' " ++
            "percent CDATA '%marker;'>]><root/>",
        true,
    );
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| {
                try std.testing.expectEqualStrings("one two three", start.attributes[0].value);
                try std.testing.expect(!start.attributes[0].specified);
                try std.testing.expectEqualStrings("%marker;", start.attributes[1].value);
                try std.testing.expect(!start.attributes[1].specified);
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
}

test "[property] - [entity memory]: repeated expansion retains a fixed active shape" {
    const config = xml.Configs.XML10_NONVALIDATING;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, .{});
    defer reader.deinit();
    var baseline: xml.MemoryUsage = .{};
    inline for (.{ @as(usize, 10), @as(usize, 10_000) }, 0..) |count, pass| {
        if (pass != 0) try reader.reset(.retain_capacity);
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(
            std.testing.allocator,
            "<!DOCTYPE root [<!ENTITY value 'payload'>]><root>",
        );
        for (0..count) |_| try input.appendSlice(std.testing.allocator, "&value;");
        try input.appendSlice(std.testing.allocator, "</root>");
        try reader.feed(input.items, true);
        var text_bytes: usize = 0;
        while (true) switch (try reader.next()) {
            .event => |event| switch (event) {
                .text => |text| text_bytes += text.bytes.len,
                else => {},
            },
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        };
        try std.testing.expectEqual(count * "payload".len, text_bytes);
        if (pass == 0) {
            baseline = reader.memoryUsage();
        } else {
            const usage = reader.memoryUsage();
            try std.testing.expectEqual(baseline.dtd_capacity, usage.dtd_capacity);
            try std.testing.expectEqual(baseline.retained_capacity, usage.retained_capacity);
        }
    }
}

test "reader - lifecycle: feed reset and deinit preserve state contract" {
    const Reader = xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer if (reader.lifecycle != .deinitialized) reader.deinit();

    try std.testing.expectEqual(xml.ProfileLifecycle.ready, reader.lifecycle);
    try reader.feed("<root/>", true);
    try std.testing.expectEqual(xml.ProfileLifecycle.producing, reader.lifecycle);
    try std.testing.expectError(error.InvalidState, reader.feed("", true));

    while (true) {
        switch (try reader.next()) {
            .event => {},
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expect(reader.memoryUsage().retained_capacity > 0);

    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(xml.ProfileLifecycle.ready, reader.lifecycle);
    try std.testing.expect(reader.diagnostic() == null);
    try std.testing.expect(reader.memoryUsage().retained_capacity > 0);

    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);

    reader.deinit();
    try std.testing.expectEqual(xml.ProfileLifecycle.deinitialized, reader.lifecycle);
    try std.testing.expectError(error.InvalidState, reader.reset(.release_memory));
}

test "reader - vertical slice: whole every-split and one-byte schedules agree" {
    const input = "<root/>";
    const whole_parts = [_][]const u8{input};
    const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &whole_parts);

    try std.testing.expectEqual(@as(u32, 1234), expected.sequence);
    try std.testing.expectEqual(@as(usize, 1), expected.starts);
    try std.testing.expectEqual(@as(usize, 1), expected.ends);

    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try std.testing.expectEqual(
            expected,
            try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts),
        );
    }
    try std.testing.expectEqual(
        expected,
        try parseOneByteChunks(CORE_CONFIG, std.testing.allocator, .{}, input),
    );
}

test "[unit] - [element structure]: nested siblings preserve names and syntax metadata" {
    try expectEvents("<root></root>", &.{
        .document_start,
        .{ .start_element = .{ .name = "root", .empty_element_syntax = false } },
        .{ .end_element = "root" },
        .document_end,
    });
    try expectEvents("<root><empty></empty><also-empty /></root>\n", &.{
        .document_start,
        .{ .start_element = .{ .name = "root", .empty_element_syntax = false } },
        .{ .start_element = .{ .name = "empty", .empty_element_syntax = false } },
        .{ .end_element = "empty" },
        .{ .start_element = .{ .name = "also-empty", .empty_element_syntax = true } },
        .{ .end_element = "also-empty" },
        .{ .end_element = "root" },
        .document_end,
    });
    try expectEvents("<root ><item /><group><leaf/></group></root >", &.{
        .document_start,
        .{ .start_element = .{ .name = "root", .empty_element_syntax = false } },
        .{ .start_element = .{ .name = "item", .empty_element_syntax = true } },
        .{ .end_element = "item" },
        .{ .start_element = .{ .name = "group", .empty_element_syntax = false } },
        .{ .start_element = .{ .name = "leaf", .empty_element_syntax = true } },
        .{ .end_element = "leaf" },
        .{ .end_element = "group" },
        .{ .end_element = "root" },
        .document_end,
    });
}

test "[property] - [element structure]: all required chunk schedules agree" {
    const input = "<root><level-one><level-two><leaf/></level-two></level-one></root>\n";
    const whole_parts = [_][]const u8{input};
    const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &whole_parts);

    try std.testing.expectEqual(@as(u64, 1222233334), expected.sequence);
    try std.testing.expectEqual(@as(usize, 4), expected.starts);
    try std.testing.expectEqual(@as(usize, 4), expected.ends);
    try std.testing.expectEqual(@as(usize, 1), expected.empty_starts);
    try std.testing.expectEqual(@as(usize, 52), expected.name_bytes);

    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try std.testing.expectEqual(
            expected,
            try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts),
        );
    }
    try std.testing.expectEqual(
        expected,
        try parseOneByteChunks(CORE_CONFIG, std.testing.allocator, .{}, input),
    );
    inline for (.{ 2, 3, 5, 7, 11 }) |chunk_size| {
        try std.testing.expectEqual(
            expected,
            try parseFixedChunks(CORE_CONFIG, std.testing.allocator, .{}, input, chunk_size),
        );
    }
    for (0..32) |seed| {
        try std.testing.expectEqual(
            expected,
            try parseRandomChunks(CORE_CONFIG, std.testing.allocator, .{}, input, seed),
        );
    }
}

test "[property] - [element structure]: explicit and empty forms agree across schedules" {
    const input = "<root><empty></empty><also-empty /></root>\n";
    const whole_parts = [_][]const u8{input};
    const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &whole_parts);

    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try std.testing.expectEqual(
            expected,
            try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts),
        );
    }
    try std.testing.expectEqual(
        expected,
        try parseOneByteChunks(CORE_CONFIG, std.testing.allocator, .{}, input),
    );
    inline for (.{ 2, 3, 5, 7, 11 }) |chunk_size| {
        try std.testing.expectEqual(
            expected,
            try parseFixedChunks(CORE_CONFIG, std.testing.allocator, .{}, input, chunk_size),
        );
    }
    for (0..8) |seed| {
        try std.testing.expectEqual(
            expected,
            try parseRandomChunks(CORE_CONFIG, std.testing.allocator, .{}, input, seed),
        );
    }
}

test "[property] - [document structure]: malformed examples have exact diagnostics" {
    try expectCoreFailureSchedules(
        "<root><item></root>\n",
        error.InvalidXml,
        .mismatched_end_tag,
        14,
        6,
    );
    try expectCoreFailureSchedules(
        "</root>\n",
        error.InvalidXml,
        .unexpected_end_tag,
        1,
        null,
    );
    try expectCoreFailureSchedules(
        "<root><item/></root\n",
        error.InvalidXml,
        .incomplete_input,
        20,
        null,
    );
    try expectCoreFailureSchedules(
        "<root></ root>\n",
        error.InvalidXml,
        .malformed_end_tag,
        8,
        null,
    );
}

test "diagnostic - end tags: unexpected mismatch malformed and truncation are exact" {
    try expectCoreFailure(
        .{},
        "</root>",
        error.InvalidXml,
        .unexpected_end_tag,
        1,
        null,
    );
    try expectCoreFailure(
        .{},
        "<root><item></root>",
        error.InvalidXml,
        .mismatched_end_tag,
        14,
        6,
    );
    try expectCoreFailure(
        .{},
        "<root></roo>",
        error.InvalidXml,
        .mismatched_end_tag,
        11,
        0,
    );
    try expectCoreFailure(
        .{},
        "<root></rootx>",
        error.InvalidXml,
        .mismatched_end_tag,
        12,
        0,
    );
    try expectCoreFailure(
        .{},
        "<root></ root>",
        error.InvalidXml,
        .malformed_end_tag,
        8,
        null,
    );
    try expectCoreFailure(
        .{},
        "<root></wrong!>",
        error.InvalidXml,
        .malformed_end_tag,
        13,
        null,
    );
    try expectCoreFailure(
        .{},
        "<root></wrong",
        error.InvalidXml,
        .incomplete_input,
        13,
        null,
    );
    try expectCoreFailure(
        .{},
        "<root><item/>",
        error.InvalidXml,
        .unclosed_element,
        13,
        0,
    );
}

test "streaming - diagnostics: mismatch is invariant across every two-way split" {
    const input = "<root><item></root>";
    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try expectCoreFailureParts(
            .{},
            &parts,
            error.InvalidXml,
            .mismatched_end_tag,
            14,
            6,
        );
    }
}

test "diagnostic - final input: structural and token truncation remain distinct" {
    const cases = [_]struct {
        input: []const u8,
        code: xml.DiagnosticCode,
        offset: u64,
        related: ?u64,
    }{
        .{ .input = "<", .code = .incomplete_input, .offset = 1, .related = null },
        .{ .input = "<root", .code = .incomplete_input, .offset = 5, .related = null },
        .{ .input = "<root ", .code = .incomplete_input, .offset = 6, .related = null },
        .{ .input = "<root/", .code = .incomplete_input, .offset = 6, .related = null },
        .{ .input = "<root/ ", .code = .malformed_start_tag, .offset = 6, .related = null },
        .{ .input = "<root>", .code = .unclosed_element, .offset = 6, .related = 0 },
        .{ .input = "<root><", .code = .incomplete_input, .offset = 7, .related = null },
        .{ .input = "<root><item", .code = .incomplete_input, .offset = 11, .related = null },
        .{ .input = "<root><item ", .code = .incomplete_input, .offset = 12, .related = null },
        .{ .input = "<root><item/", .code = .incomplete_input, .offset = 12, .related = null },
        .{ .input = "<root><item/>", .code = .unclosed_element, .offset = 13, .related = 0 },
        .{ .input = "<root></", .code = .incomplete_input, .offset = 8, .related = null },
        .{ .input = "<root></root", .code = .incomplete_input, .offset = 12, .related = null },
        .{ .input = "<root></root ", .code = .incomplete_input, .offset = 13, .related = null },
    };
    for (cases) |case| {
        try expectCoreFailure(
            .{},
            case.input,
            error.InvalidXml,
            case.code,
            case.offset,
            case.related,
        );
    }
}

test "adapter - whole slice: uses the same event and lifetime contract" {
    const SliceReader = xml.ProfileSliceReader(CORE_CONFIG);
    var slice = try SliceReader.init(std.testing.allocator, .{}, "<root><item key='value'/></root>");
    defer slice.deinit();

    var summary: Summary = .{};
    while (true) {
        switch (try slice.next()) {
            .event => |event| try summary.observe(event),
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expectEqual(@as(u32, 122334), summary.sequence);
    try std.testing.expectEqual(@as(usize, 1), summary.attributes);
    try std.testing.expectEqual(@as(usize, 3), summary.attribute_name_bytes);
    try std.testing.expectEqual(@as(usize, 5), summary.attribute_value_bytes);
}

test "adapter - std Io Reader: greedy buffered refill handles one-byte source reads" {
    var io_buffer: [3]u8 = undefined;
    var source: std.testing.Reader = .init(&io_buffer, &.{
        .{ .buffer = "<root><item key='value'/></root>" },
    });
    source.artificial_limit = .limited(1);

    const IoReader = xml.ProfileIoReader(CORE_CONFIG);
    var input = try IoReader.init(std.testing.allocator, .{}, &source.interface);
    defer input.deinit();

    var summary: Summary = .{};
    while (true) {
        switch (try input.next()) {
            .event => |event| try summary.observe(event),
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expectEqual(@as(u32, 122334), summary.sequence);
    try std.testing.expectEqual(@as(usize, 1), summary.attributes);
}

test "[failure] - [buffered reader]: source failure is stable and allocation-free" {
    var source_buffer: [1]u8 = undefined;
    var source = std.Io.Reader.failing;
    source.buffer = &source_buffer;
    var input = try xml.ProfileIoReader(CORE_CONFIG).init(
        std.testing.allocator,
        .{},
        &source,
    );
    defer input.deinit();

    try std.testing.expectError(error.ReadFailed, input.next());
    const diagnostic = input.diagnostic().?;
    try std.testing.expectEqual(xml.DiagnosticCode.read_failed, diagnostic.code);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.primary.byte_offset);
    try std.testing.expectEqual(@as(usize, 0), input.memoryUsage().retained_capacity);
    try std.testing.expectError(error.ReadFailed, input.next());
}

test "adapter - push drain: preserves event order and explicit cancellation" {
    var complete: PushContext = .{};
    try xml.drainProfileSlice(
        CORE_CONFIG,
        std.testing.allocator,
        .{},
        "<root><item/></root>",
        &complete,
        pushObserve,
    );
    try std.testing.expectEqual(@as(usize, 6), complete.events);
    try std.testing.expectEqual(@as(usize, 0), complete.attributes);

    var markup: PushContext = .{};
    try xml.drainProfileSlice(
        CORE_CONFIG,
        std.testing.allocator,
        .{},
        "<?pi?><r><!----><![CDATA[x]]></r>",
        &markup,
        pushObserve,
    );
    try std.testing.expectEqual(@as(usize, 7), markup.events);

    var attributed: PushContext = .{};
    try xml.drainProfileSlice(
        CORE_CONFIG,
        std.testing.allocator,
        .{},
        "<root key='value'/>",
        &attributed,
        pushObserve,
    );
    try std.testing.expectEqual(@as(usize, 4), attributed.events);
    try std.testing.expectEqual(@as(usize, 1), attributed.attributes);

    var cancelled: PushContext = .{ .cancel_after = 2 };
    try std.testing.expectError(
        error.Cancelled,
        xml.drainProfileSlice(
            CORE_CONFIG,
            std.testing.allocator,
            .{},
            "<root><item/></root>",
            &cancelled,
            pushObserve,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), cancelled.events);
}

test "reader - vertical slice: whitespace and event spans use source positions" {
    const located_config = xml.Configs.XML10_UTF8_NO_DTD_LOCATED;
    const Reader = xml.ReaderFor(located_config);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();

    try reader.feed("\r\n<root/>\n", true);
    var saw_start = false;
    while (true) {
        switch (try reader.next()) {
            .event => |event| switch (event.payload) {
                .start_element => {
                    saw_start = true;
                    try std.testing.expectEqual(@as(u64, 2), event.span.start.byte_offset);
                    try std.testing.expectEqual(@as(u64, 2), event.span.start.line);
                    try std.testing.expectEqual(@as(u64, 1), event.span.start.byte_column);
                    try std.testing.expectEqual(@as(u64, 9), event.span.end.byte_offset);
                },
                else => {},
            },
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expect(saw_start);
}

test "location - nested elements: explicit end spans use closing markup positions" {
    const located_config = xml.Configs.XML10_UTF8_NO_DTD_LOCATED;
    const Reader = xml.ReaderFor(located_config);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<root><item/></root>", true);

    var root_end_seen = false;
    while (true) {
        switch (try reader.next()) {
            .event => |event| switch (event.payload) {
                .end_element => |end| {
                    if (std.mem.eql(u8, end.name.raw, "root")) {
                        root_end_seen = true;
                        try std.testing.expectEqual(@as(u64, 13), event.span.start.byte_offset);
                        try std.testing.expectEqual(@as(u64, 20), event.span.end.byte_offset);
                    }
                },
                else => {},
            },
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expect(root_end_seen);
}

test "reader - diagnostics: invalid document categories are sticky and exact" {
    const Reader = xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD_FAST);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();

    try reader.feed("<root/>x", true);
    _ = try reader.next();
    _ = try reader.next();
    _ = try reader.next();
    try std.testing.expectError(error.InvalidXml, reader.next());
    try std.testing.expectEqual(xml.DiagnosticCode.trailing_content, reader.diagnostic().?.code);
    try std.testing.expectEqual(@as(u64, 7), reader.diagnostic().?.primary.byte_offset);
    try std.testing.expectError(error.InvalidXml, reader.next());

    try reader.reset(.release_memory);
    try std.testing.expect(reader.diagnostic() == null);

    try reader.feed("<root/><again/>", true);
    _ = try reader.next();
    _ = try reader.next();
    _ = try reader.next();
    try std.testing.expectError(error.InvalidXml, reader.next());
    try std.testing.expectEqual(
        xml.DiagnosticCode.multiple_document_elements,
        reader.diagnostic().?.code,
    );
}

test "reader - diagnostics: line and byte column survive CRLF and whitespace" {
    const Reader = xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();

    try reader.feed("\r\n<root/>\n x", true);
    _ = try reader.next();
    _ = try reader.next();
    _ = try reader.next();
    try std.testing.expectError(error.InvalidXml, reader.next());
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(@as(u64, 11), diagnostic.primary.byte_offset);
    try std.testing.expectEqual(@as(u64, 3), diagnostic.primary.line);
    try std.testing.expectEqual(@as(u64, 2), diagnostic.primary.byte_column);
}

test "location - mismatch diagnostic: primary and related locations retain line detail" {
    const Reader = xml.ReaderFor(CORE_CONFIG);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("\r\n<root><item></root>", true);

    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        };
    }
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(xml.DiagnosticCode.mismatched_end_tag, diagnostic.code);
    try std.testing.expectEqual(@as(u64, 16), diagnostic.primary.byte_offset);
    try std.testing.expectEqual(@as(u64, 2), diagnostic.primary.line);
    try std.testing.expectEqual(@as(u64, 15), diagnostic.primary.byte_column);
    try std.testing.expectEqual(@as(u64, 8), diagnostic.related.?.byte_offset);
    try std.testing.expectEqual(@as(u64, 2), diagnostic.related.?.line);
    try std.testing.expectEqual(@as(u64, 7), diagnostic.related.?.byte_column);
}

test "reader - diagnostics: empty text-only malformed and incomplete inputs differ" {
    const cases = [_]struct {
        input: []const u8,
        code: xml.DiagnosticCode,
        offset: u64,
    }{
        .{ .input = "", .code = .empty_document, .offset = 0 },
        .{ .input = "text", .code = .unexpected_document_text, .offset = 0 },
        .{ .input = "<root!/>", .code = .malformed_start_tag, .offset = 5 },
        .{ .input = "<root/", .code = .incomplete_input, .offset = 6 },
    };

    inline for (cases) |case| {
        const Reader = xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD_FAST);
        var reader = try Reader.init(std.testing.allocator, .{});
        defer reader.deinit();

        try reader.feed(case.input, true);
        _ = try reader.next();
        try std.testing.expectError(error.InvalidXml, reader.next());
        try std.testing.expectEqual(case.code, reader.diagnostic().?.code);
        try std.testing.expectEqual(case.offset, reader.diagnostic().?.primary.byte_offset);
    }
}

test "[property] - [document text]: UTF-8 before, after, and without a root is exact" {
    const cases = [_]struct {
        input: []const u8,
        code: xml.DiagnosticCode,
        offset: u64,
    }{
        .{ .input = " \né<r/>", .code = .unexpected_document_text, .offset = 2 },
        .{ .input = "<r/>é", .code = .trailing_content, .offset = 4 },
        .{ .input = "é", .code = .unexpected_document_text, .offset = 0 },
    };
    for (cases) |case| {
        try expectCoreFailureSchedules(
            case.input,
            error.InvalidXml,
            case.code,
            case.offset,
            null,
        );
    }
}

test "[property] - [attributes]: source order and values survive every schedule" {
    const input = "<root first=\"one\" second='two' third = \"three\" fourth= 'four'/>\n";
    try expectEvents(input, &.{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &.{
                .{ .name = "first", .value = "one" },
                .{ .name = "second", .value = "two" },
                .{ .name = "third", .value = "three" },
                .{ .name = "fourth", .value = "four" },
            },
            .empty_element_syntax = true,
        } },
        .{ .end_element = "root" },
        .document_end,
    });

    try expectSummarySchedules(input, .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 8,
        .attributes = 4,
        .attribute_name_bytes = 22,
        .attribute_value_bytes = 15,
    });
}

test "[property] - [attributes]: repeated start events retain exact zero one and many semantics" {
    try expectSummarySchedules("<root/>", .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 8,
    });
    try expectSummarySchedules("<root key='value'></root>", .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .name_bytes = 8,
        .attributes = 1,
        .attribute_name_bytes = 3,
        .attribute_value_bytes = 5,
    });
    try expectSummarySchedules(MANY_ATTRIBUTES, .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 8,
        .attributes = 17,
        .attribute_name_bytes = 17,
        .attribute_value_bytes = 24,
    });

    const nested = "<root parent='one'><child leaf='two'/></root>";
    try expectEvents(nested, &.{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &.{.{ .name = "parent", .value = "one" }},
            .empty_element_syntax = false,
        } },
        .{ .start_element = .{
            .name = "child",
            .attributes = &.{.{ .name = "leaf", .value = "two" }},
            .empty_element_syntax = true,
        } },
        .{ .end_element = "child" },
        .{ .end_element = "root" },
        .document_end,
    });
    try expectSummarySchedules(nested, .{
        .sequence = 122334,
        .starts = 2,
        .ends = 2,
        .empty_starts = 1,
        .name_bytes = 18,
        .attributes = 2,
        .attribute_name_bytes = 10,
        .attribute_value_bytes = 6,
    });
}

test "[property] - [attributes]: syntax whitespace is legal across every chunk boundary" {
    const input = "<root\tfirst \r=\n'one'\nsecond= \"two\"\r/>";
    try expectEvents(input, &.{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &.{
                .{ .name = "first", .value = "one" },
                .{ .name = "second", .value = "two" },
            },
            .empty_element_syntax = true,
        } },
        .{ .end_element = "root" },
        .document_end,
    });
    try expectSummarySchedules(input, .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 8,
        .attributes = 2,
        .attribute_name_bytes = 11,
        .attribute_value_bytes = 6,
    });
}

test "[edge] - [attributes]: nonquadratic duplicate path preserves source order" {
    var input_buffer: [2048]u8 = undefined;
    const input = try makeAttributeInput(&input_buffer, 65, false);
    const SliceReader = xml.ProfileSliceReader(CORE_CONFIG);
    var reader = try SliceReader.init(std.testing.allocator, .{}, input);
    defer reader.deinit();

    _ = try reader.next();
    const step = try reader.next();
    switch (step) {
        .event => |event| switch (event) {
            .start_element => |start| {
                try std.testing.expectEqual(@as(usize, 65), start.attributes.len);
                for (start.attributes, 0..) |attribute, index| {
                    var expected_name_buffer: [32]u8 = undefined;
                    const expected_name = try std.fmt.bufPrint(
                        &expected_name_buffer,
                        "a{d}",
                        .{index},
                    );
                    try std.testing.expectEqualStrings(expected_name, attribute.name.raw);
                    var expected_value_buffer: [32]u8 = undefined;
                    const expected_value = try std.fmt.bufPrint(
                        &expected_value_buffer,
                        "{d}",
                        .{index},
                    );
                    try std.testing.expectEqualStrings(expected_value, attribute.value);
                }
            },
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    }

    try expectSummarySchedules(input, .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 8,
        .attributes = 65,
        .attribute_name_bytes = 185,
        .attribute_value_bytes = 120,
    });
}

test "[failure] - [attributes]: malformed forms have exact diagnostics" {
    try expectCoreFailureSchedules(
        "<root value=\"one\" value=\"two\"/>\n",
        error.InvalidXml,
        .duplicate_attribute,
        18,
        6,
    );
    try expectCoreFailureSchedules(
        "<root value=unquoted/>\n",
        error.InvalidXml,
        .malformed_attribute,
        12,
        null,
    );
    try expectCoreFailureSchedules(
        "<root value \"missing\"/>\n",
        error.InvalidXml,
        .malformed_attribute,
        12,
        null,
    );
    try expectCoreFailureSchedules(
        "<root value=\"illegal<character\"/>\n",
        error.InvalidXml,
        .attribute_less_than,
        20,
        null,
    );
    const truncated = "<root value=\"never closed>\n";
    try expectCoreFailureSchedules(
        truncated,
        error.InvalidXml,
        .incomplete_input,
        truncated.len,
        null,
    );
    try expectCoreFailureSchedules(
        "<r a='1'b='2'/>",
        error.InvalidXml,
        .malformed_attribute,
        8,
        null,
    );
}

test "[failure] - [attributes]: syntax errors prevent atomic start publication" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<root first='one' second='two' first='three'/>", true);

    var start_count: usize = 0;
    while (true) {
        const step = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        };
        switch (step) {
            .event => |event| switch (event) {
                .start_element => start_count += 1,
                else => {},
            },
            .need_input => return error.UnexpectedNeedInput,
            .done => return error.ExpectedFailure,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), start_count);
    try std.testing.expectEqual(xml.DiagnosticCode.duplicate_attribute, reader.diagnostic().?.code);
}

test "[failure] - [attribute diagnostics]: complete syntax precedes duplicate reporting" {
    try expectCoreFailureSchedules(
        "<r a='1' a='2' bad>",
        error.InvalidXml,
        .malformed_attribute,
        18,
        null,
    );
}

test "[property] - [attribute normalization]: literal whitespace and references are semantic" {
    const expected_attributes = [_]ExpectedAttribute{
        .{ .name = "value", .value = "one two three" },
        .{ .name = "tabs", .value = "one\ttwo" },
        .{ .name = "newlines", .value = "one\ntwo" },
    };
    const expected_events = [_]ExpectedEvent{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &expected_attributes,
            .empty_element_syntax = true,
        } },
        .{ .end_element = "root" },
        .document_end,
    };
    try expectEvents(
        "<root value=\"one two three\" tabs=\"one&#9;two\" newlines=\"one&#10;two\"/>\n",
        &expected_events,
    );

    const literal_whitespace = "<root value='one\ttwo\r\nthree\rfour\nfive'/>";
    const expected_literal = [_]ExpectedAttribute{
        .{ .name = "value", .value = "one two three four five" },
    };
    const expected_literal_events = [_]ExpectedEvent{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &expected_literal,
            .empty_element_syntax = true,
        } },
        .{ .end_element = "root" },
        .document_end,
    };
    try expectEvents(literal_whitespace, &expected_literal_events);

    const utf8_widths = "<root value='é漢🙂'/>";
    const expected_utf8_attributes = [_]ExpectedAttribute{
        .{ .name = "value", .value = "é漢🙂" },
    };
    const expected_utf8_events = [_]ExpectedEvent{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &expected_utf8_attributes,
            .empty_element_syntax = true,
        } },
        .{ .end_element = "root" },
        .document_end,
    };
    try expectEvents(utf8_widths, &expected_utf8_events);
    try expectSemanticSchedules(utf8_widths, "", 1, 1, 1);
}

test "[property] - [text]: mixed content concatenates under every input schedule" {
    try expectSemanticSchedules(
        "<paragraph>before <emphasis role=\"strong\">inside</emphasis> " ++
            "after <empty/> tail</paragraph>\n",
        "before inside after  tail",
        3,
        3,
        1,
    );
}

test "[property] - [references]: predefined and numeric values are semantic" {
    const predefined =
        "<root attribute=\"&lt;&gt;&amp;&quot;&apos;\">&lt;&gt;&amp;&quot;&apos;</root>\n";
    const numeric =
        "<root decimal=\"&#65;\" hexadecimal=\"&#x41;\">" ++
        "&#9;&#10;&#13;&#x20;&#x1F642;</root>\n";
    try expectSemanticSchedules(
        predefined,
        "<>&\"'",
        1,
        1,
        1,
    );
    try expectSemanticSchedules(
        numeric,
        "\t\n\r 🙂",
        1,
        1,
        2,
    );

    const predefined_attributes = [_]ExpectedAttribute{
        .{ .name = "attribute", .value = "<>&\"'" },
    };
    const predefined_events = [_]ExpectedEvent{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &predefined_attributes,
            .empty_element_syntax = false,
        } },
        .{ .text = "<" },
        .{ .text = ">" },
        .{ .text = "&" },
        .{ .text = "\"" },
        .{ .text = "'" },
        .{ .end_element = "root" },
        .document_end,
    };
    try expectEvents(predefined, &predefined_events);

    const numeric_attributes = [_]ExpectedAttribute{
        .{ .name = "decimal", .value = "A" },
        .{ .name = "hexadecimal", .value = "A" },
    };
    const numeric_events = [_]ExpectedEvent{
        .document_start,
        .{ .start_element = .{
            .name = "root",
            .attributes = &numeric_attributes,
            .empty_element_syntax = false,
        } },
        .{ .text = "\t" },
        .{ .text = "\n" },
        .{ .text = "\r" },
        .{ .text = " " },
        .{ .text = "🙂" },
        .{ .end_element = "root" },
        .document_end,
    };
    try expectEvents(numeric, &numeric_events);
}

test "[property] - [UTF-8]: BOM and scalar widths survive every split" {
    try expectSemanticSchedules("\xef\xbb\xbf<root>é🙂</root>", "é🙂", 1, 1, 0);
    try expectSemanticSchedules(
        "<root>\xc2\x80\xe0\xa0\x80\xf0\x90\x80\x80\xf4\x8f\xbf\xbf</root>",
        "ࠀ𐀀􏿿",
        1,
        1,
        0,
    );
    try expectSemanticSchedules(
        "<root>ASCII, e acute: é, CJK: 漢字, emoji: 🙂</root>\n",
        "ASCII, e acute: é, CJK: 漢字, emoji: 🙂",
        1,
        1,
        0,
    );
}

test "[property] - [UTF-16]: byte order code units and surrogates survive every split" {
    const little_parts = [_][]const u8{UTF16LE_BOM};
    const little = try parseParts(GENERAL_CONFIG, std.testing.allocator, .{}, &little_parts);
    try std.testing.expectEqual(xml.SourceEncoding.utf16_le, little.source_encoding);
    try std.testing.expectEqualStrings("UTF-16", little.declared_encoding[0..little.declared_encoding_len]);
    try std.testing.expectEqualStrings("λ🙂", little.text_bytes[0..little.text_bytes_len]);
    try expectSummarySchedulesWithOptions(GENERAL_CONFIG, .{}, UTF16LE_BOM, little);

    const big_parts = [_][]const u8{UTF16BE_BOM};
    const big = try parseParts(GENERAL_CONFIG, std.testing.allocator, .{}, &big_parts);
    try std.testing.expectEqual(xml.SourceEncoding.utf16_be, big.source_encoding);
    try std.testing.expectEqualStrings("UTF-16", big.declared_encoding[0..big.declared_encoding_len]);
    try std.testing.expectEqualStrings("λ🙂", big.text_bytes[0..big.text_bytes_len]);
    try expectSummarySchedulesWithOptions(GENERAL_CONFIG, .{}, UTF16BE_BOM, big);
}

test "[property] - [general UTF-8]: direct source path agrees across schedules" {
    const input = "<根 a='é'>x\r\ny🙂</根>";
    const parts = [_][]const u8{input};
    const summary = try parseParts(GENERAL_CONFIG, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqual(xml.SourceEncoding.utf8, summary.source_encoding);
    try std.testing.expectEqualStrings("x\ny🙂", summary.text_bytes[0..summary.text_bytes_len]);
    try expectSummarySchedulesWithOptions(GENERAL_CONFIG, .{}, input, summary);

    var reader = try xml.ReaderFor(GENERAL_FAST_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    try drainGeneralChunks(&reader, input);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().decoder_capacity);
}

test "[failure] - [UTF-16]: odd bytes and unpaired surrogates have stable source offsets" {
    try expectGeneralFailureSchedules(
        UTF16LE_ODD_BYTE,
        .malformed_encoding,
        UTF16LE_ODD_BYTE.len - 1,
    );
    try expectGeneralFailureSchedules(
        UTF16LE_UNPAIRED_HIGH,
        .malformed_encoding,
        14,
    );
    try expectGeneralFailureSchedules(
        UTF16BE_UNPAIRED_LOW,
        .malformed_encoding,
        14,
    );
}

test "[property] - [UTF-16 declaration]: explicit endian labels agree with detection" {
    inline for (.{
        .{ .endian = TestEndian.little, .label = "UTF-16LE", .encoding = xml.SourceEncoding.utf16_le },
        .{ .endian = TestEndian.big, .label = "UTF-16BE", .encoding = xml.SourceEncoding.utf16_be },
    }) |case| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "<?xml version='1.0' encoding='{s}'?><根 a='é'>x\r\ny🙂</根>",
            .{case.label},
        );
        defer std.testing.allocator.free(source);
        const encoded = try encodeUtf16(std.testing.allocator, source, case.endian, true);
        defer std.testing.allocator.free(encoded);
        const parts = [_][]const u8{encoded};
        const summary = try parseParts(GENERAL_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqual(case.encoding, summary.source_encoding);
        try std.testing.expectEqualStrings(
            case.label,
            summary.declared_encoding[0..summary.declared_encoding_len],
        );
        try std.testing.expectEqualStrings("x\ny🙂", summary.text_bytes[0..summary.text_bytes_len]);
        try expectSummarySchedulesWithOptions(GENERAL_CONFIG, .{}, encoded, summary);
    }
}

test "[failure] - [encoding detection]: missing signatures and declaration conflicts are exact" {
    const no_signature = try encodeUtf16(std.testing.allocator, "<?xml version='1.0'?><r/>", .big, false);
    defer std.testing.allocator.free(no_signature);
    try expectGeneralFailureSchedules(no_signature, .missing_encoding_signature, 0);

    const mismatch_source = "<?xml version='1.0' encoding='UTF-16BE'?><r/>";
    const mismatch = try encodeUtf16(
        std.testing.allocator,
        mismatch_source,
        .little,
        true,
    );
    defer std.testing.allocator.free(mismatch);
    const encoding_index = std.mem.indexOf(u8, mismatch_source, "UTF-16BE").?;
    try expectGeneralFailureSchedules(
        mismatch,
        .encoding_mismatch,
        2 + 2 * encoding_index,
    );

    const declared_utf16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><root/>";
    try expectGeneralFailureSchedules(
        declared_utf16,
        .encoding_mismatch,
        std.mem.indexOf(u8, declared_utf16, "UTF-16").?,
    );

    const unsupported_four_byte_signatures = [_][4]u8{
        "\x00\x00\xfe\xff".*,
        "\xff\xfe\x00\x00".*,
        "\x00\x00\xff\xfe".*,
        "\xfe\xff\x00\x00".*,
        "\x00\x00\x00\x3c".*,
        "\x3c\x00\x00\x00".*,
        "\x00\x00\x3c\x00".*,
        "\x00\x3c\x00\x00".*,
    };
    for (unsupported_four_byte_signatures) |signature| {
        try expectProfileFailureSchedules(
            GENERAL_FAST_CONFIG,
            .{},
            &signature,
            error.UnsupportedFeature,
            .unsupported_encoding,
            0,
            null,
        );
    }
}

test "[integration] - [buffered UTF-16]: one-byte source reads preserve semantics" {
    var io_buffer: [5]u8 = undefined;
    var source: std.testing.Reader = .init(&io_buffer, &.{.{ .buffer = UTF16LE_BOM }});
    source.artificial_limit = .limited(1);
    var input = try xml.ProfileIoReader(GENERAL_CONFIG).init(
        std.testing.allocator,
        .{},
        &source.interface,
    );
    defer input.deinit();
    var summary: Summary = .{};
    while (true) switch (try input.next()) {
        .event => |event| try summary.observe(event),
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(xml.SourceEncoding.utf16_le, summary.source_encoding);
    try std.testing.expectEqualStrings("λ🙂", summary.text_bytes[0..summary.text_bytes_len]);
}

test "[integration] - [UTF-16 namespaces]: decoded names use the namespace reader" {
    const source = "<根 xmlns:p='urn:x'><p:子 a='値'/></根>";
    const encoded = try encodeUtf16(std.testing.allocator, source, .little, true);
    defer std.testing.allocator.free(encoded);
    const parts = [_][]const u8{encoded};
    const summary = try parseParts(
        xml.Configs.XML10_NAMESPACES_NO_DTD,
        std.testing.allocator,
        .{},
        &parts,
    );
    try std.testing.expectEqual(@as(usize, 2), summary.starts);
    try std.testing.expectEqual(@as(usize, 1), summary.namespace_declarations);
    try std.testing.expectEqual(@as(usize, 1), summary.attributes);
}

test "[failure] - [UTF-16 storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationUtf16Parse,
        .{},
    );
}

test "[property] - [UTF-16 memory]: decoded storage is independent of document length" {
    var document: std.ArrayList(u8) = .empty;
    defer document.deinit(std.testing.allocator);
    try document.appendSlice(std.testing.allocator, "<r>");
    try document.appendNTimes(std.testing.allocator, 'x', 512 * 1024);
    try document.appendSlice(std.testing.allocator, "</r>");
    const encoded = try encodeUtf16(
        std.testing.allocator,
        document.items,
        .little,
        true,
    );
    defer std.testing.allocator.free(encoded);

    var reader = try xml.ReaderFor(GENERAL_FAST_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    try drainGeneralChunks(&reader, encoded);
    const capacity = reader.memoryUsage().decoder_capacity;
    try std.testing.expectEqual(@as(usize, 2 * 16 * 1024), capacity);

    try reader.reset(.retain_capacity);
    try drainGeneralChunks(&reader, UTF16LE_BOM);
    try std.testing.expectEqual(capacity, reader.memoryUsage().decoder_capacity);
    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().decoder_capacity);
}

test "[failure] - [UTF-16 locations]: grammar diagnostics use original byte offsets" {
    const source = "<r>\r\n<x></y></r>";
    const encoded = try encodeUtf16(std.testing.allocator, source, .little, true);
    defer std.testing.allocator.free(encoded);
    const mismatch_index = std.mem.indexOf(u8, source, "y").?;
    try expectProfileFailureSchedules(
        GENERAL_CONFIG,
        .{},
        encoded,
        error.InvalidXml,
        .mismatched_end_tag,
        2 + 2 * mismatch_index,
        2 + 2 * std.mem.indexOf(u8, source, "<x").?,
    );

    const parts = [_][]const u8{encoded};
    const Reader = xml.ReaderFor(GENERAL_CONFIG);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(parts[0], true);
    while (true) {
        _ = reader.next() catch break;
    }
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(@as(u64, 2), diagnostic.primary.line);
    try std.testing.expectEqual(@as(u64, 11), diagnostic.primary.byte_column);
}

test "[property] - [line normalization]: CR and CRLF produce one LF" {
    try expectSemanticSchedules("<root>one\rtwo\r</root>\r", "one\ntwo\n", 1, 1, 0);
    try expectSemanticSchedules("<root>one\r\ntwo\r\n</root>\r\n", "one\ntwo\n", 1, 1, 0);
}

test "[integration] - [buffered UTF-8]: one-byte source reads preserve semantics" {
    const source_bytes = "<文 属性='a&#9;b'>é\r\n🙂&amp;</文>";
    var io_buffer: [5]u8 = undefined;
    var source: std.testing.Reader = .init(&io_buffer, &.{.{ .buffer = source_bytes }});
    source.artificial_limit = .limited(1);

    var input = try xml.ProfileIoReader(CORE_CONFIG).init(
        std.testing.allocator,
        .{},
        &source.interface,
    );
    defer input.deinit();
    var summary: Summary = .{};
    while (true) {
        switch (try input.next()) {
            .event => |event| try summary.observe(event),
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), summary.attributes);
    try std.testing.expectEqualStrings(
        "é\n🙂&",
        summary.text_bytes[0..summary.text_bytes_len],
    );
}

test "[integration] - [buffered markup]: one-byte source reads preserve markup semantics" {
    const source_bytes =
        "<?xml version=\"1.0\"?>\n" ++
        "<!--before-->\n" ++
        "<?setup ready?>\n" ++
        "<root>content</root>\n" ++
        "<?done?>\n" ++
        "<!--after-->\n";
    var io_buffer: [7]u8 = undefined;
    var source: std.testing.Reader = .init(
        &io_buffer,
        &.{.{ .buffer = source_bytes }},
    );
    source.artificial_limit = .limited(1);

    var input = try xml.ProfileIoReader(CORE_CONFIG).init(
        std.testing.allocator,
        .{},
        &source.interface,
    );
    defer input.deinit();
    var summary: Summary = .{};
    while (true) {
        switch (try input.next()) {
            .event => |event| try summary.observe(event),
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expectEqualStrings(
        "beforeafter",
        summary.comment_bytes[0..summary.comment_bytes_len],
    );
    try std.testing.expectEqualStrings(
        "setup\x00ready\xffdone\x00\xff",
        summary.processing_instruction_bytes[0..summary.processing_instruction_bytes_len],
    );
}

test "[integration] - [XML names]: Fifth Edition names preserve UTF-8 bytes" {
    const unicode_names = "<文書 属性=\"値\"><項目/></文書>\n";
    const unicode_attributes = [_]ExpectedAttribute{
        .{ .name = "属性", .value = "値" },
    };
    const unicode_events = [_]ExpectedEvent{
        .document_start,
        .{ .start_element = .{
            .name = "文書",
            .attributes = &unicode_attributes,
            .empty_element_syntax = false,
        } },
        .{ .start_element = .{
            .name = "項目",
            .empty_element_syntax = true,
        } },
        .{ .end_element = "項目" },
        .{ .end_element = "文書" },
        .document_end,
    };
    try expectEvents(unicode_names, &unicode_events);
    try expectSemanticSchedules(unicode_names, "", 2, 2, 1);

    const name_character_events = [_]ExpectedEvent{
        .document_start,
        .{ .start_element = .{ .name = "_root", .empty_element_syntax = false } },
        .{ .start_element = .{ .name = "a-b", .empty_element_syntax = true } },
        .{ .end_element = "a-b" },
        .{ .start_element = .{ .name = "a.b", .empty_element_syntax = true } },
        .{ .end_element = "a.b" },
        .{ .start_element = .{ .name = "name_2", .empty_element_syntax = true } },
        .{ .end_element = "name_2" },
        .{ .start_element = .{ .name = "éclair", .empty_element_syntax = true } },
        .{ .end_element = "éclair" },
        .{ .end_element = "_root" },
        .document_end,
    };
    const name_characters = "<_root><a-b/><a.b/><name_2/><éclair/></_root>\n";
    try expectEvents(name_characters, &name_character_events);
    try expectSemanticSchedules(name_characters, "", 5, 5, 0);
}

test "[property] - [XML names]: Fifth Edition range boundaries are exact" {
    const valid_start_boundaries = [_]u21{
        0xc0,   0xd6,   0xd8,   0xf6,   0xf8,    0x2ff,
        0x370,  0x37d,  0x37f,  0x1fff, 0x200c,  0x200d,
        0x2070, 0x218f, 0x2c00, 0x2fef, 0x3001,  0xd7ff,
        0xf900, 0xfdcf, 0xfdf0, 0xfffd, 0x10000, 0xeffff,
    };
    var buffer: [16]u8 = undefined;
    for (valid_start_boundaries) |codepoint| {
        const input = try makeNameDocument(&buffer, codepoint, true);
        const parts = [_][]const u8{input};
        const summary = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqual(@as(usize, 1), summary.starts);
        try std.testing.expectEqual(@as(usize, 1), summary.ends);
    }

    const valid_char_only = [_]u21{ 0xb7, 0x300, 0x36f, 0x203f, 0x2040 };
    for (valid_char_only) |codepoint| {
        const input = try makeNameDocument(&buffer, codepoint, false);
        const parts = [_][]const u8{input};
        const summary = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqual(@as(usize, 1), summary.starts);
    }

    const excluded = [_]u21{ 0xb7, 0x37e, 0x200b, 0x200e, 0x2fff, 0xf8ff, 0xfdd0, 0xf0000 };
    for (excluded) |codepoint| {
        const input = try makeNameDocument(&buffer, codepoint, true);
        try expectCoreFailure(
            .{},
            input,
            error.InvalidXml,
            .malformed_start_tag,
            1,
            null,
        );
    }
}

test "[failure] - [references]: malformed, illegal, and undeclared forms are exact" {
    const malformed = "<root>&#xZZ;</root>\n";
    const malformed_offset = std.mem.indexOfScalar(
        u8,
        malformed,
        'Z',
    ).?;
    try expectCoreFailureSchedules(
        malformed,
        error.InvalidXml,
        .malformed_reference,
        @intCast(malformed_offset),
        null,
    );
    inline for (.{
        "<root>&#0;</root>\n",
        "<root>&#xD800;</root>\n",
        "<root>&#x110000;</root>\n",
        "<root>&#999999999999999999999999;</root>",
    }) |input| {
        const offset = std.mem.indexOfScalar(u8, input, '&').?;
        try expectCoreFailureSchedules(
            input,
            error.InvalidXml,
            .invalid_character_reference,
            @intCast(offset),
            null,
        );
    }
    const undefined_entity = "<root>&undefined;</root>\n";
    const undefined_offset = std.mem.indexOfScalar(u8, undefined_entity, '&').?;
    try expectCoreFailureSchedules(
        undefined_entity,
        error.InvalidXml,
        .undeclared_entity,
        @intCast(undefined_offset),
        null,
    );
    const truncated = "<root>&amp</root>\n";
    const truncated_offset = std.mem.indexOf(u8, truncated[1..], "<").? + 1;
    try expectCoreFailureSchedules(
        truncated,
        error.InvalidXml,
        .malformed_reference,
        @intCast(truncated_offset),
        null,
    );
}

test "[failure] - [character data]: literal CDATA close is rejected across schedules" {
    const input = "<root>illegal ]]&gt; sequence: ]]></root>\n";
    const close = std.mem.lastIndexOf(u8, input, "]]>").?;
    try expectCoreFailureSchedules(
        input,
        error.InvalidXml,
        .cdata_close_in_text,
        @intCast(close + 2),
        null,
    );
}

test "[failure] - [UTF-8]: invalid sequence diagnostics identify the first invalid byte" {
    const cases = [_]struct {
        input: []const u8,
        offset: u64,
    }{
        .{ .input = "<root>\x80</root>", .offset = 6 },
        .{ .input = "<root>\xc0\xaf</root>", .offset = 6 },
        .{ .input = "<root>\xe2\x82</root>", .offset = 8 },
        .{ .input = "<root>\xed\xa0\x80</root>", .offset = 7 },
        .{ .input = "<root>\xf4\x90\x80\x80</root>", .offset = 7 },
        .{ .input = "<root>\xff</root>", .offset = 6 },
    };
    for (cases) |case| {
        try expectCoreFailureSchedules(
            case.input,
            error.InvalidXml,
            .malformed_utf8,
            case.offset,
            null,
        );
    }
}

test "[failure] - [UTF-8 contexts]: markup, names, values, and references validate first" {
    const cases = [_][]const u8{
        "<\xe2(/>",
        "<r \xe2(='x'/>",
        "<r a='\xe2('/>",
        "<r a='x'\xe2(/>",
        "<r></\xe2(>",
        "<r>&\xe2(;</r>",
        "<r>&#\xe2(;</r>",
        "<r/><\xe2(",
    };
    for (cases) |input| {
        const offset = std.mem.indexOfScalar(u8, input, '(').?;
        try expectCoreFailureSchedules(
            input,
            error.InvalidXml,
            .malformed_utf8,
            @intCast(offset),
            null,
        );
    }
}

test "[failure] - [XML characters]: literal forbidden scalars are exact" {
    inline for (.{ "<root>before\x00after</root>", "<root>before\x01after</root>" }) |input| {
        const offset = std.mem.indexOfAny(u8, input, "\x00\x01").?;
        try expectCoreFailureSchedules(
            input,
            error.InvalidXml,
            .forbidden_character,
            @intCast(offset),
            null,
        );
    }
    try expectCoreFailureSchedules(
        "<root>\xef\xbf\xbe</root>",
        error.InvalidXml,
        .forbidden_character,
        6,
        null,
    );
}

test "[failure] - [line diagnostics]: normalized endings retain source-byte locations" {
    const input = "<r>\r\nok\r\x01</r>";
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);

    while (true) {
        const step = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        };
        if (step == .done) return error.ExpectedFailure;
    }
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(xml.DiagnosticCode.forbidden_character, diagnostic.code);
    try std.testing.expectEqual(@as(u64, 8), diagnostic.primary.byte_offset);
    try std.testing.expectEqual(@as(u64, 3), diagnostic.primary.line);
    try std.testing.expectEqual(@as(u64, 1), diagnostic.primary.byte_column);
}

test "[integration] - [text locations]: source spans cover borrowed and transformed input" {
    const located_config = xml.Configs.XML10_UTF8_NO_DTD_LOCATED;
    const Reader = xml.ReaderFor(located_config);
    const expected = [_]struct {
        text: []const u8,
        start: u64,
        end: u64,
    }{
        .{ .text = "ab", .start = 3, .end = 5 },
        .{ .text = "&", .start = 5, .end = 10 },
        .{ .text = "\n", .start = 10, .end = 12 },
        .{ .text = "🙂", .start = 12, .end = 16 },
    };

    var reader = try Reader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<r>ab&amp;\r\n🙂</r>", true);

    var index: usize = 0;
    while (true) {
        switch (try reader.next()) {
            .event => |event| switch (event.payload) {
                .text => |text| {
                    try std.testing.expect(index < expected.len);
                    try std.testing.expectEqualStrings(expected[index].text, text.bytes);
                    try std.testing.expectEqual(
                        expected[index].start,
                        event.span.start.byte_offset,
                    );
                    try std.testing.expectEqual(expected[index].end, event.span.end.byte_offset);
                    index += 1;
                },
                else => {},
            },
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expectEqual(expected.len, index);
}

test "[integration] - [event locations]: declaration span and PI target lifetime are exact" {
    const located_config = xml.Configs.XML10_UTF8_NO_DTD_LOCATED;
    const Reader = xml.ReaderFor(located_config);
    var options: xml.OptionsFor(located_config) = .{};
    options.limits.max_fragment_bytes = 4;
    const input = "<?xml version='1.0'?><?target abcdef?><r/>";

    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed(input, true);

    const declaration_end = std.mem.indexOf(u8, input, "?>").? + 2;
    const start = switch (try reader.next()) {
        .event => |event| switch (event.payload) {
            .document_start => |document| blk: {
                try std.testing.expectEqualStrings("1.0", document.declared_version.?);
                try std.testing.expectEqual(xml.XmlVersion.xml10, document.effective_version);
                try std.testing.expectEqual(xml.SourceEncoding.utf8, document.source_encoding);
                try std.testing.expectEqual(@as(u64, 0), event.span.start.byte_offset);
                try std.testing.expectEqual(
                    @as(u64, @intCast(declaration_end)),
                    event.span.end.byte_offset,
                );
                break :blk document.declared_version.?;
            },
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };
    try std.testing.expectEqualStrings("1.0", start);

    var instruction_bytes: [6]u8 = undefined;
    var instruction_len: usize = 0;
    var completed = false;
    while (!completed) {
        switch (try reader.next()) {
            .event => |event| switch (event.payload) {
                .processing_instruction => |instruction| {
                    try std.testing.expectEqualStrings("target", instruction.target);
                    @memcpy(
                        instruction_bytes[instruction_len..][0..instruction.data.len],
                        instruction.data,
                    );
                    instruction_len += instruction.data.len;
                    completed = instruction.complete;
                },
                else => return error.UnexpectedEvent,
            },
            else => return error.UnexpectedStep,
        }
    }
    try std.testing.expectEqualStrings("abcdef", instruction_bytes[0..instruction_len]);
}

test "[edge] - [text fragments]: limits preserve scalars and expose schedule counts" {
    var core_options: xml.OptionsFor(CORE_CONFIG) = .{};
    core_options.limits.max_fragment_bytes = 4;
    const input = "<r>abcdefghij</r>";

    var whole_reader = try CoreReader.init(std.testing.allocator, core_options);
    defer whole_reader.deinit();
    try whole_reader.feed(input, true);
    var whole_run: TextRun = .{};
    try std.testing.expect(try drainTextBoundary(&whole_reader, &whole_run));
    try std.testing.expectEqual(@as(usize, 10), whole_run.bytes);
    try std.testing.expectEqual(@as(usize, 3), whole_run.fragments);

    var byte_reader = try CoreReader.init(std.testing.allocator, core_options);
    defer byte_reader.deinit();
    var byte_run: TextRun = .{};
    for (input, 0..) |_, index| {
        try byte_reader.feed(input[index .. index + 1], index + 1 == input.len);
        const done = try drainTextBoundary(&byte_reader, &byte_run);
        if (index + 1 == input.len) {
            try std.testing.expect(done);
        } else {
            try std.testing.expect(!done);
        }
    }
    try std.testing.expectEqual(@as(usize, 10), byte_run.bytes);
    try std.testing.expectEqual(@as(usize, 10), byte_run.fragments);

    var failure_options: xml.OptionsFor(FAST_CONFIG) = .{};
    failure_options.limits.max_fragment_bytes = 1;
    try expectCoreFailureSchedulesWithOptions(
        failure_options,
        "<r>aé</r>",
        error.LimitExceeded,
        .fragment_limit,
        4,
        null,
    );
    try expectCoreFailureSchedulesWithOptions(
        failure_options,
        "<r>&#x1F642;</r>",
        error.LimitExceeded,
        .fragment_limit,
        3,
        null,
    );
}

test "[edge] - [reference limits]: partial and normalized value boundaries are exact" {
    var options: xml.OptionsFor(FAST_CONFIG) = .{};
    options.limits.max_partial_token_bytes = 5;
    const input = "<r>&amp;</r>";
    const parts = [_][]const u8{input};
    const expected = try parseParts(FAST_CONFIG, std.testing.allocator, options, &parts);
    try std.testing.expectEqualStrings("&", expected.text_bytes[0..expected.text_bytes_len]);
    try expectSummarySchedulesWithOptions(FAST_CONFIG, options, input, expected);

    options.limits.max_partial_token_bytes = 4;
    try expectCoreFailureSchedulesWithOptions(
        options,
        input,
        error.LimitExceeded,
        .partial_token_limit,
        7,
        null,
    );

    options = .{};
    options.limits.max_partial_token_bytes = 2;
    const unicode_name = "<é/>";
    const unicode_parts = [_][]const u8{unicode_name};
    const unicode_expected = try parseParts(
        FAST_CONFIG,
        std.testing.allocator,
        options,
        &unicode_parts,
    );
    try expectSummarySchedulesWithOptions(
        FAST_CONFIG,
        options,
        unicode_name,
        unicode_expected,
    );
    options.limits.max_partial_token_bytes = 1;
    try expectCoreFailureSchedulesWithOptions(
        options,
        unicode_name,
        error.LimitExceeded,
        .partial_token_limit,
        1,
        null,
    );

    const attribute_input = "<r a='&#x1F642;'/>";
    options = .{};
    options.limits.max_attribute_value_bytes = 4;
    const attribute_parts = [_][]const u8{attribute_input};
    _ = try parseParts(FAST_CONFIG, std.testing.allocator, options, &attribute_parts);
    options.limits.max_attribute_value_bytes = 3;
    const after_semicolon = std.mem.indexOfScalar(u8, attribute_input, ';').? + 1;
    try expectCoreFailureSchedulesWithOptions(
        options,
        attribute_input,
        error.LimitExceeded,
        .attribute_value_limit,
        @intCast(after_semicolon),
        null,
    );

    options = .{};
    options.limits.max_attribute_bytes_per_element = 5;
    _ = try parseParts(FAST_CONFIG, std.testing.allocator, options, &attribute_parts);
    options.limits.max_attribute_bytes_per_element = 4;
    try expectCoreFailureSchedulesWithOptions(
        options,
        attribute_input,
        error.LimitExceeded,
        .attribute_bytes_limit,
        @intCast(after_semicolon),
        null,
    );
}

test "[failure] - [text storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationTextParse,
        .{},
    );
}

test "[property] - [streaming memory]: increasing text retains fixed parser capacity" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();

    const small = try parseRepeatedText(&reader, 1024);
    try std.testing.expectEqual(@as(usize, 1024), small.bytes);
    const retained = reader.memoryUsage().retained_capacity;

    try reader.reset(.retain_capacity);
    const large = try parseRepeatedText(&reader, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), large.bytes);
    try std.testing.expectEqual(retained, reader.memoryUsage().retained_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().scratch_capacity);
}

test "[unit] - [text lifetime]: borrowed and transformed fragments survive one event" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<r>abc&amp;</r>", true);

    _ = try reader.next();
    _ = try reader.next();
    const borrowed = switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |text| text.bytes,
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };
    try std.testing.expectEqualStrings("abc", borrowed);
    const transformed = switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |text| text.bytes,
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };
    try std.testing.expectEqualStrings("&", transformed);
}

test "[unit] - [text reset]: pending scalar, reference, and CR state is discarded" {
    const partials = [_][]const u8{ "<r>\xe2", "<r>&amp", "<r>\r" };
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    for (partials) |partial| {
        try reader.feed(partial, false);
        while (true) {
            switch (try reader.next()) {
                .event => {},
                .need_input => break,
                .done => return error.UnexpectedDone,
            }
        }
        try reader.reset(.retain_capacity);
        try reader.feed("<ok/>", true);
        const summary = try drainCore(&reader);
        try std.testing.expectEqual(@as(usize, 1), summary.starts);
        try reader.reset(.retain_capacity);
    }
}

test "[property] - [declaration]: metadata is final before document start across schedules" {
    const input =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<root/>\n";
    const parts = [_][]const u8{input};
    const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqualStrings(
        "1.0",
        expected.declared_version[0..expected.declared_version_len],
    );
    try std.testing.expectEqualStrings(
        "UTF-8",
        expected.declared_encoding[0..expected.declared_encoding_len],
    );
    try std.testing.expect(expected.standalone);
    try std.testing.expect(expected.standalone_declared);
    try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, input, expected);

    const version_input = "<?xml version='1.7'?><r/>";
    const version_parts = [_][]const u8{version_input};
    const version = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &version_parts);
    try std.testing.expectEqualStrings(
        "1.7",
        version.declared_version[0..version.declared_version_len],
    );

    const default_input = "<r/>";
    const default_parts = [_][]const u8{default_input};
    const defaults = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &default_parts);
    try std.testing.expectEqual(@as(usize, 0), defaults.declared_version_len);
    try std.testing.expectEqual(@as(usize, 0), defaults.declared_encoding_len);
    try std.testing.expect(!defaults.standalone);
    try std.testing.expect(!defaults.standalone_declared);

    const stylesheet_input = "<?xml-stylesheet href='style.css'?><r/>";
    const stylesheet_parts = [_][]const u8{stylesheet_input};
    const stylesheet = try parseParts(
        CORE_CONFIG,
        std.testing.allocator,
        .{},
        &stylesheet_parts,
    );
    try std.testing.expectEqualStrings(
        "xml-stylesheet\x00href='style.css'\xff",
        stylesheet.processing_instruction_bytes[0..stylesheet.processing_instruction_bytes_len],
    );
    try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, stylesheet_input, stylesheet);
}

test "[property] - [event summaries]: comments processing instructions CDATA and records agree across schedules" {
    {
        const input =
            "<?xml version=\"1.0\"?>\n" ++
            "<!--before-->\n" ++
            "<?setup ready?>\n" ++
            "<root>content</root>\n" ++
            "<?done?>\n" ++
            "<!--after-->\n";
        const parts = [_][]const u8{input};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqualStrings(
            "content",
            expected.text_bytes[0..expected.text_bytes_len],
        );
        try std.testing.expectEqualStrings(
            "beforeafter",
            expected.comment_bytes[0..expected.comment_bytes_len],
        );
        try std.testing.expectEqual(@as(usize, 2), expected.complete_comments);
        try std.testing.expectEqualStrings(
            "setup\x00ready\xffdone\x00\xff",
            expected.processing_instruction_bytes[0..expected.processing_instruction_bytes_len],
        );
        try expectSummarySchedulesWithOptions(
            CORE_CONFIG,
            .{},
            input,
            expected,
        );
    }
    {
        const input = "<root><!-- hyphen-allowed --><!--empty--></root>\n";
        const parts = [_][]const u8{input};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqualStrings(
            " hyphen-allowed empty",
            expected.comment_bytes[0..expected.comment_bytes_len],
        );
        try std.testing.expectEqual(@as(usize, 2), expected.complete_comments);
        try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, input, expected);
    }
    {
        const input = "<?before data?><root><?inside more data?></root><?after?>\n";
        const parts = [_][]const u8{input};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqualStrings(
            "before\x00data\xffinside\x00more data\xffafter\x00\xff",
            expected.processing_instruction_bytes[0..expected.processing_instruction_bytes_len],
        );
        try std.testing.expectEqual(@as(usize, 3), expected.complete_processing_instructions);
        try expectSummarySchedulesWithOptions(
            CORE_CONFIG,
            .{},
            input,
            expected,
        );
    }
    {
        const input = "<root><![CDATA[<not-markup>&not-an-entity;]]></root>\n";
        const parts = [_][]const u8{input};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        const text = "<not-markup>&not-an-entity;";
        try std.testing.expectEqualStrings(text, expected.text_bytes[0..expected.text_bytes_len]);
        try std.testing.expectEqualStrings(text, expected.cdata_bytes[0..expected.cdata_bytes_len]);
        try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, input, expected);
    }
    {
        const input =
            "<catalog>\n" ++
            "  <entry id=\"a\" kind=\"short\">alpha</entry>\n" ++
            "  <entry id='medium-id' kind='mixed'>\n" ++
            "    <title>Title &amp; &#x03bb;</title>\n" ++
            "    <meta key=\"one\" value=\"1\"/>\n" ++
            "    <meta key='two' value='2'/>\n" ++
            "    <![CDATA[tail <raw>]]>\n" ++
            "  </entry>\n" ++
            "  <entry id=\"longer-id-0003\" kind=\"unicode\">é λ 🙂</entry>\n" ++
            "</catalog>\n";
        const parts = [_][]const u8{input};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqual(@as(usize, 7), expected.starts);
        try std.testing.expectEqual(@as(usize, 10), expected.attributes);
        try std.testing.expectEqualStrings(
            "tail <raw>",
            expected.cdata_bytes[0..expected.cdata_bytes_len],
        );
        try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, input, expected);
    }
}

test "[failure] - [declaration]: syntax placement version and encoding are distinct" {
    const attribute_order = "<?xml encoding=\"UTF-8\" version=\"1.0\"?><root/>\n";
    const order_offset = std.mem.indexOf(u8, attribute_order, "encoding").?;
    try expectCoreFailureSchedules(
        attribute_order,
        error.InvalidXml,
        .malformed_declaration,
        @intCast(order_offset),
        null,
    );
    const not_first = "<!--before--><?xml version=\"1.0\"?><root/>\n";
    const misplaced_offset = std.mem.indexOf(u8, not_first, "<?xml").?;
    try expectCoreFailureSchedules(
        not_first,
        error.InvalidXml,
        .misplaced_xml_declaration,
        @intCast(misplaced_offset),
        null,
    );
    const duplicate = "<?xml version=\"1.0\"?><?xml version=\"1.0\"?><root/>\n";
    const duplicate_offset = std.mem.lastIndexOf(u8, duplicate, "<?xml").?;
    try expectCoreFailureSchedules(
        duplicate,
        error.InvalidXml,
        .misplaced_xml_declaration,
        @intCast(duplicate_offset),
        null,
    );
    const unsupported_version = "<?xml version=\"2.0\"?><root/>\n";
    const version_offset = std.mem.indexOf(u8, unsupported_version, "2.0").?;
    try expectCoreFailureSchedules(
        unsupported_version,
        error.InvalidXml,
        .unsupported_version,
        @intCast(version_offset),
        null,
    );
    const encodings = [_]struct {
        input: []const u8,
        value: []const u8,
    }{
        .{ .input = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><root/>", .value = "UTF-16" },
        .{ .input = "<?xml version=\"1.0\" encoding=\"US-ASCII\"?><root>ASCII</root>", .value = "US-ASCII" },
        .{ .input = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><root>caf\xe9</root>", .value = "ISO-8859-1" },
        .{ .input = "<?xml version=\"1.0\" encoding=\"US-ASCII\"?><root>é</root>", .value = "US-ASCII" },
    };
    for (encodings) |encoding| {
        const encoding_offset = std.mem.indexOf(u8, encoding.input, encoding.value).?;
        try expectCoreFailureSchedules(
            encoding.input,
            error.UnsupportedFeature,
            .unsupported_encoding,
            @intCast(encoding_offset),
            null,
        );
    }
}

test "[failure] - [markup constructs]: malformed comments processing instructions CDATA and DOCTYPE are exact" {
    const double_hyphen = "<root><!-- invalid -- comment --></root>\n";
    const comment_offset = std.mem.indexOf(u8, double_hyphen, "-- comment").? + 2;
    try expectCoreFailureSchedules(
        double_hyphen,
        error.InvalidXml,
        .malformed_comment,
        @intCast(comment_offset),
        null,
    );
    const unclosed_comment = "<root><!-- never closed</root>\n";
    try expectCoreFailureSchedules(
        unclosed_comment,
        error.InvalidXml,
        .unclosed_comment,
        @intCast(unclosed_comment.len),
        null,
    );
    const reserved_target = "<root><?XmL reserved?></root>\n";
    const pi_offset = std.mem.indexOf(u8, reserved_target, "<?XmL").?;
    try expectCoreFailureSchedules(
        reserved_target,
        error.InvalidXml,
        .reserved_processing_instruction_target,
        @intCast(pi_offset),
        null,
    );
    const unclosed_cdata = "<root><![CDATA[never closed</root>\n";
    try expectCoreFailureSchedules(
        unclosed_cdata,
        error.InvalidXml,
        .unclosed_cdata,
        @intCast(unclosed_cdata.len),
        null,
    );
    const doctype_after_root = "<root/><!DOCTYPE root>\n";
    const misplaced_doctype = std.mem.indexOf(u8, doctype_after_root, "<!DOCTYPE").?;
    try expectCoreFailureSchedules(
        doctype_after_root,
        error.InvalidXml,
        .misplaced_doctype,
        @intCast(misplaced_doctype),
        null,
    );
    try expectCoreFailureSchedules(
        "<!DOCTYPE root><!DOCTYPE root><root/>\n",
        error.UnsupportedFeature,
        .dtd_forbidden,
        0,
        null,
    );

    const direct = [_]struct {
        input: []const u8,
        code: xml.DiagnosticCode,
        offset: u64,
    }{
        .{ .input = "<r><??></r>", .code = .malformed_processing_instruction, .offset = 5 },
        .{ .input = "<r><?1?></r>", .code = .malformed_processing_instruction, .offset = 5 },
        .{ .input = "<![CDATA[x]]><r/>", .code = .malformed_cdata, .offset = 0 },
        .{ .input = "<r/><![CDATA[x]]>", .code = .malformed_cdata, .offset = 4 },
        .{ .input = "<r><!--x---></r>", .code = .malformed_comment, .offset = 10 },
        .{ .input = "<r><!X></r>", .code = .malformed_markup_declaration, .offset = 5 },
    };
    for (direct) |case| {
        try expectCoreFailureSchedules(
            case.input,
            error.InvalidXml,
            case.code,
            case.offset,
            null,
        );
    }
}

test "[failure] - [document characters]: malformed UTF-8 and forbidden bytes win in data" {
    const malformed = [_][]const u8{
        "<?xml \xe2(?><r/>",
        "<r><!--\xe2(--></r>",
        "<r><?pi \xe2(?></r>",
        "<r><![CDATA[\xe2(]]></r>",
        "<r><![C\xe2(</r>",
    };
    for (malformed) |input| {
        const offset = std.mem.indexOfScalar(u8, input, '(').?;
        try expectCoreFailureSchedules(
            input,
            error.InvalidXml,
            .malformed_utf8,
            @intCast(offset),
            null,
        );
    }

    const forbidden = [_][]const u8{
        "<?xml \x01?><r/>",
        "<r><!--\x01--></r>",
        "<r><?pi \x01?></r>",
        "<r><![CDATA[\x01]]></r>",
    };
    for (forbidden) |input| {
        const offset = std.mem.indexOfScalar(u8, input, 1).?;
        try expectCoreFailureSchedules(
            input,
            error.InvalidXml,
            .forbidden_character,
            @intCast(offset),
            null,
        );
    }

    const late_bom = "<?xml version='1.0'?>\xef\xbb\xbf<r/>";
    const bom_offset = std.mem.indexOf(u8, late_bom, "\xef\xbb\xbf").?;
    try expectCoreFailureSchedules(
        late_bom,
        error.InvalidXml,
        .unexpected_document_text,
        @intCast(bom_offset),
        null,
    );
}

test "[edge] - [markup fragments]: limits preserve complete comments processing instructions and CDATA" {
    var options: xml.OptionsFor(CORE_CONFIG) = .{};
    options.limits.max_fragment_bytes = 4;
    const input = "<?target abcdefgh?><r><!--abcdefgh--><![CDATA[abcdefgh]]></r>";
    const parts = [_][]const u8{input};
    const expected = try parseParts(CORE_CONFIG, std.testing.allocator, options, &parts);
    try std.testing.expectEqualStrings(
        "target\x00abcdefgh\xff",
        expected.processing_instruction_bytes[0..expected.processing_instruction_bytes_len],
    );
    try std.testing.expectEqualStrings(
        "abcdefgh",
        expected.comment_bytes[0..expected.comment_bytes_len],
    );
    try std.testing.expectEqualStrings(
        "abcdefgh",
        expected.cdata_bytes[0..expected.cdata_bytes_len],
    );
    try expectSummarySchedulesWithOptions(CORE_CONFIG, options, input, expected);

    var target_options: xml.OptionsFor(FAST_CONFIG) = .{};
    target_options.limits.max_processing_instruction_target_bytes = 3;
    try expectCoreFailureSchedulesWithOptions(
        target_options,
        "<?abcd?><r/>",
        error.LimitExceeded,
        .processing_instruction_target_limit,
        5,
        null,
    );

    var delimiter_options: xml.OptionsFor(FAST_CONFIG) = .{};
    delimiter_options.limits.max_partial_token_bytes = 2;
    try expectCoreFailureSchedulesWithOptions(
        delimiter_options,
        "<r><!--x--></r>",
        error.LimitExceeded,
        .partial_token_limit,
        6,
        null,
    );
}

test "[failure] - [markup storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationMarkupParse,
        .{},
    );
}

test "[property] - [markup normalization]: comments processing instructions and CDATA normalize line endings" {
    const input = "<r><!--a\r\né--><?π a\r\né?><![CDATA[a\r\né]]]></r>";
    const parts = [_][]const u8{input};
    const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqualStrings(
        "a\né",
        expected.comment_bytes[0..expected.comment_bytes_len],
    );
    try std.testing.expectEqualStrings(
        "π\x00a\né\xff",
        expected.processing_instruction_bytes[0..expected.processing_instruction_bytes_len],
    );
    try std.testing.expectEqualStrings(
        "a\né]",
        expected.cdata_bytes[0..expected.cdata_bytes_len],
    );
    try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, input, expected);
}

test "[property] - [markup fragments]: comments processing instructions and CDATA preserve borrowed UTF-8 runs" {
    const input = "<r><!--é🙂--><?pi é🙂?><![CDATA[é🙂]]></r>";
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);

    var comment_fragments: usize = 0;
    var instruction_fragments: usize = 0;
    var cdata_fragments: usize = 0;
    while (true) {
        switch (try reader.next()) {
            .event => |event| switch (event) {
                .comment => |comment| {
                    comment_fragments += 1;
                    if (comment.complete) {
                        try std.testing.expectEqual(@as(usize, 0), comment.bytes.len);
                    } else {
                        try std.testing.expectEqualStrings("é🙂", comment.bytes);
                    }
                },
                .processing_instruction => |instruction| {
                    instruction_fragments += 1;
                    try std.testing.expectEqualStrings("pi", instruction.target);
                    if (instruction.complete) {
                        try std.testing.expectEqual(@as(usize, 0), instruction.data.len);
                    } else {
                        try std.testing.expectEqualStrings("é🙂", instruction.data);
                    }
                },
                .text => |text| if (text.origin == .cdata) {
                    cdata_fragments += 1;
                    try std.testing.expectEqualStrings("é🙂", text.bytes);
                },
                else => {},
            },
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), comment_fragments);
    try std.testing.expectEqual(@as(usize, 2), instruction_fragments);
    try std.testing.expectEqual(@as(usize, 1), cdata_fragments);
}

test "[edge] - [declaration grammar]: quoting whitespace ordering and values are exact" {
    const valid =
        "<?xml\r\nversion = '1.0'\r\nencoding='utf-8'\r\nstandalone = \"no\" ?>" ++
        "<r/>";
    const parts = [_][]const u8{valid};
    const summary = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqualStrings(
        "utf-8",
        summary.declared_encoding[0..summary.declared_encoding_len],
    );
    try std.testing.expect(!summary.standalone);
    try std.testing.expect(summary.standalone_declared);
    try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, valid, summary);

    const malformed = [_]struct {
        input: []const u8,
        diagnostic_offset: u64,
    }{
        .{ .input = "<?xml?><r/>", .diagnostic_offset = 0 },
        .{
            .input = "<?xml Version='1.0'?><r/>",
            .diagnostic_offset = std.mem.indexOf(u8, "<?xml Version='1.0'?><r/>", "Version").?,
        },
        .{
            .input = "<?xml version='1.a'?><r/>",
            .diagnostic_offset = std.mem.indexOf(u8, "<?xml version='1.a'?><r/>", "1.a").?,
        },
        .{
            .input = "<?xml version='1.0' version='1.0'?><r/>",
            .diagnostic_offset = std.mem.lastIndexOf(u8, "<?xml version='1.0' version='1.0'?><r/>", "version").?,
        },
        .{
            .input = "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><r/>",
            .diagnostic_offset = std.mem.indexOf(u8, "<?xml version='1.0' standalone='yes' encoding='UTF-8'?><r/>", "encoding").?,
        },
        .{
            .input = "<?xml version='1.0' standalone='maybe'?><r/>",
            .diagnostic_offset = std.mem.indexOf(u8, "<?xml version='1.0' standalone='maybe'?><r/>", "maybe").?,
        },
        .{
            .input = "<?xml é?><r/>",
            .diagnostic_offset = std.mem.indexOf(u8, "<?xml é?><r/>", "é").?,
        },
    };
    for (malformed) |case| {
        try expectCoreFailureSchedules(
            case.input,
            error.InvalidXml,
            .malformed_declaration,
            case.diagnostic_offset,
            null,
        );
    }
}

test "[failure] - [markup delimiters]: every proper final prefix has a stable category" {
    const cases = [_]struct {
        input: []const u8,
        code: xml.DiagnosticCode,
    }{
        .{ .input = "<r><!", .code = .incomplete_input },
        .{ .input = "<r><!-", .code = .incomplete_input },
        .{ .input = "<r><!--", .code = .unclosed_comment },
        .{ .input = "<r><!--x-", .code = .unclosed_comment },
        .{ .input = "<r><!--x--", .code = .unclosed_comment },
        .{ .input = "<r><![", .code = .incomplete_input },
        .{ .input = "<r><![C", .code = .incomplete_input },
        .{ .input = "<r><![CD", .code = .incomplete_input },
        .{ .input = "<r><![CDA", .code = .incomplete_input },
        .{ .input = "<r><![CDAT", .code = .incomplete_input },
        .{ .input = "<r><![CDATA", .code = .incomplete_input },
        .{ .input = "<r><![CDATA[", .code = .unclosed_cdata },
        .{ .input = "<r><![CDATA[x]", .code = .unclosed_cdata },
        .{ .input = "<r><![CDATA[x]]", .code = .unclosed_cdata },
        .{ .input = "<r><?", .code = .incomplete_processing_instruction },
        .{ .input = "<r><?pi", .code = .incomplete_processing_instruction },
        .{ .input = "<r><?pi?", .code = .incomplete_processing_instruction },
        .{ .input = "<?", .code = .incomplete_processing_instruction },
        .{ .input = "<?x", .code = .incomplete_processing_instruction },
        .{ .input = "<?xm", .code = .incomplete_processing_instruction },
        .{ .input = "<?xml", .code = .incomplete_declaration },
        .{ .input = "<?xml ", .code = .incomplete_declaration },
        .{ .input = "<?xml version='1.0'?", .code = .incomplete_declaration },
        .{ .input = "<!D", .code = .incomplete_input },
        .{ .input = "<!DO", .code = .incomplete_input },
        .{ .input = "<!DOC", .code = .incomplete_input },
        .{ .input = "<!DOCT", .code = .incomplete_input },
        .{ .input = "<!DOCTY", .code = .incomplete_input },
        .{ .input = "<!DOCTYP", .code = .incomplete_input },
    };
    for (cases) |case| {
        try expectCoreFailureSchedules(
            case.input,
            error.InvalidXml,
            case.code,
            @intCast(case.input.len),
            null,
        );
    }
}

test "[edge] - [markup limits]: at-limit values pass and multibyte excess fails" {
    var short_target_options: xml.OptionsFor(FAST_CONFIG) = .{};
    short_target_options.limits.max_processing_instruction_target_bytes = 1;
    const declaration_with_short_target_limit = "<?xml version='1.0'?><r/>";
    const declaration_with_short_target_parts = [_][]const u8{
        declaration_with_short_target_limit,
    };
    const declaration_with_short_target_summary = try parseParts(
        FAST_CONFIG,
        std.testing.allocator,
        short_target_options,
        &declaration_with_short_target_parts,
    );
    try expectSummarySchedulesWithOptions(
        FAST_CONFIG,
        short_target_options,
        declaration_with_short_target_limit,
        declaration_with_short_target_summary,
    );

    const short_target_pi = "<?a?><r/>";
    const short_target_pi_parts = [_][]const u8{short_target_pi};
    const short_target_pi_summary = try parseParts(
        FAST_CONFIG,
        std.testing.allocator,
        short_target_options,
        &short_target_pi_parts,
    );
    try expectSummarySchedulesWithOptions(
        FAST_CONFIG,
        short_target_options,
        short_target_pi,
        short_target_pi_summary,
    );
    try expectCoreFailureSchedulesWithOptions(
        short_target_options,
        "<?ab?><r/>",
        error.LimitExceeded,
        .processing_instruction_target_limit,
        3,
        null,
    );
    try expectCoreFailureSchedulesWithOptions(
        short_target_options,
        "<?xml-stylesheet?><r/>",
        error.LimitExceeded,
        .processing_instruction_target_limit,
        3,
        null,
    );

    var options: xml.OptionsFor(CORE_CONFIG) = .{};
    options.limits.max_processing_instruction_target_bytes = 4;
    options.limits.max_fragment_bytes = 2;
    const valid = "<?abcd é?><r><!--é--><![CDATA[é]]></r>";
    const parts = [_][]const u8{valid};
    const summary = try parseParts(CORE_CONFIG, std.testing.allocator, options, &parts);
    try std.testing.expectEqualStrings(
        "abcd\x00é\xff",
        summary.processing_instruction_bytes[0..summary.processing_instruction_bytes_len],
    );
    try std.testing.expectEqualStrings("é", summary.comment_bytes[0..summary.comment_bytes_len]);
    try std.testing.expectEqualStrings("é", summary.cdata_bytes[0..summary.cdata_bytes_len]);

    var unicode_target_options: xml.OptionsFor(FAST_CONFIG) = .{};
    unicode_target_options.limits.max_processing_instruction_target_bytes = 2;
    const unicode_target_parts = [_][]const u8{"<?é?><r/>"};
    _ = try parseParts(
        FAST_CONFIG,
        std.testing.allocator,
        unicode_target_options,
        &unicode_target_parts,
    );
    unicode_target_options.limits.max_processing_instruction_target_bytes = 1;
    try expectCoreFailureSchedulesWithOptions(
        unicode_target_options,
        "<?é?><r/>",
        error.LimitExceeded,
        .processing_instruction_target_limit,
        2,
        null,
    );

    var delimiter_options: xml.OptionsFor(CORE_CONFIG) = .{};
    delimiter_options.limits.max_partial_token_bytes = 3;
    const comment_parts = [_][]const u8{"<r><!----></r>"};
    _ = try parseParts(
        CORE_CONFIG,
        std.testing.allocator,
        delimiter_options,
        &comment_parts,
    );

    var cdata_delimiter_options: xml.OptionsFor(FAST_CONFIG) = .{};
    cdata_delimiter_options.limits.max_partial_token_bytes = 8;
    const cdata_delimiter_parts = [_][]const u8{"<r><![CDATA[x]]></r>"};
    _ = try parseParts(
        FAST_CONFIG,
        std.testing.allocator,
        cdata_delimiter_options,
        &cdata_delimiter_parts,
    );
    cdata_delimiter_options.limits.max_partial_token_bytes = 7;
    try expectCoreFailureSchedulesWithOptions(
        cdata_delimiter_options,
        "<r><![CDATA[x]]></r>",
        error.LimitExceeded,
        .partial_token_limit,
        11,
        null,
    );

    var declaration_options: xml.OptionsFor(FAST_CONFIG) = .{};
    declaration_options.limits.max_partial_token_bytes = 21;
    const declaration_parts = [_][]const u8{"<?xml version='1.0'?><r/>"};
    _ = try parseParts(
        FAST_CONFIG,
        std.testing.allocator,
        declaration_options,
        &declaration_parts,
    );
    declaration_options.limits.max_partial_token_bytes = 20;
    try expectCoreFailureSchedulesWithOptions(
        declaration_options,
        "<?xml version='1.0'?><r/>",
        error.LimitExceeded,
        .partial_token_limit,
        20,
        null,
    );

    declaration_options.limits.max_partial_token_bytes = 6;
    try expectCoreFailureSchedulesWithOptions(
        declaration_options,
        "<?xml é?><r/>",
        error.LimitExceeded,
        .partial_token_limit,
        6,
        null,
    );

    for (1..6) |opener_limit| {
        declaration_options.limits.max_partial_token_bytes = opener_limit;
        try expectCoreFailureSchedulesWithOptions(
            declaration_options,
            "<?xml version='1.0'?><r/>",
            error.LimitExceeded,
            .partial_token_limit,
            @intCast(opener_limit),
            null,
        );
    }

    var bracket_options: xml.OptionsFor(CORE_CONFIG) = .{};
    bracket_options.limits.max_fragment_bytes = 1;
    const bracket_input = "<r><![CDATA[]]x]]]></r>";
    const bracket_parts = [_][]const u8{bracket_input};
    const bracket_summary = try parseParts(
        CORE_CONFIG,
        std.testing.allocator,
        bracket_options,
        &bracket_parts,
    );
    try std.testing.expectEqualStrings(
        "]]x]",
        bracket_summary.cdata_bytes[0..bracket_summary.cdata_bytes_len],
    );
    try expectSummarySchedulesWithOptions(
        CORE_CONFIG,
        bracket_options,
        bracket_input,
        bracket_summary,
    );

    var fragment_options: xml.OptionsFor(FAST_CONFIG) = .{};
    fragment_options.limits.max_fragment_bytes = 1;
    inline for (.{
        "<r><!--é--></r>",
        "<r><?pi é?></r>",
        "<r><![CDATA[é]]></r>",
    }) |input| {
        const scalar_offset = std.mem.indexOf(u8, input, "é").?;
        try expectCoreFailureSchedulesWithOptions(
            fragment_options,
            input,
            error.LimitExceeded,
            .fragment_limit,
            @intCast(scalar_offset),
            null,
        );
    }
}

test "[property] - [markup memory]: increasing comments retain fixed parser capacity" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();

    const small = try parseRepeatedComment(&reader, 1024);
    try std.testing.expectEqual(@as(usize, 1024), small.bytes);
    try std.testing.expectEqual(@as(usize, 1), small.complete);
    const retained = reader.memoryUsage().retained_capacity;

    try reader.reset(.retain_capacity);
    const large = try parseRepeatedComment(&reader, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), large.bytes);
    try std.testing.expectEqual(@as(usize, 1), large.complete);
    try std.testing.expectEqual(retained, reader.memoryUsage().retained_capacity);

    try reader.reset(.retain_capacity);
    const small_instruction = try parseRepeatedProcessingInstruction(&reader, 1024);
    try std.testing.expectEqual(@as(usize, 1024), small_instruction.bytes);
    try std.testing.expectEqual(@as(usize, 1), small_instruction.complete);
    const instruction_retained = reader.memoryUsage().retained_capacity;

    try reader.reset(.retain_capacity);
    const large_instruction = try parseRepeatedProcessingInstruction(&reader, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), large_instruction.bytes);
    try std.testing.expectEqual(@as(usize, 1), large_instruction.complete);
    try std.testing.expectEqual(
        instruction_retained,
        reader.memoryUsage().retained_capacity,
    );
}

test "[unit] - [markup reset]: pending declaration and delimiter state is discarded" {
    const partials = [_][]const u8{
        "<?xml version='1.0'",
        "<r><!--partial",
        "<r><![CDATA[partial]",
        "<r><?target partial?",
    };
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    for (partials) |partial| {
        try reader.feed(partial, false);
        while (true) {
            switch (try reader.next()) {
                .event => {},
                .need_input => break,
                .done => return error.UnexpectedDone,
            }
        }
        try reader.reset(.retain_capacity);
        try reader.feed("<ok/>", true);
        const summary = try drainCore(&reader);
        try std.testing.expectEqual(@as(usize, 1), summary.starts);
        try reader.reset(.retain_capacity);
    }
}

test "[failure] - [attributes]: duplicate names remain exact above the linear threshold" {
    var input_buffer: [2048]u8 = undefined;
    const input = try makeAttributeInput(&input_buffer, 66, true);
    const first = std.mem.indexOf(u8, input, "a0='").?;
    const second = std.mem.lastIndexOf(u8, input, "a0='").?;
    try expectCoreFailureSchedules(
        input,
        error.InvalidXml,
        .duplicate_attribute,
        @intCast(second),
        @intCast(first),
    );
}

test "[failure] - [attribute diagnostics]: duplicate locations retain line detail" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("\n<r a='1'\n a='2'/>", true);

    while (true) {
        const step = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        };
        if (step == .done) return error.ExpectedFailure;
    }
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(xml.DiagnosticCode.duplicate_attribute, diagnostic.code);
    try std.testing.expectEqual(@as(u64, 11), diagnostic.primary.byte_offset);
    try std.testing.expectEqual(@as(u64, 3), diagnostic.primary.line);
    try std.testing.expectEqual(@as(u64, 2), diagnostic.primary.byte_column);
    try std.testing.expectEqual(@as(u64, 4), diagnostic.related.?.byte_offset);
    try std.testing.expectEqual(@as(u64, 2), diagnostic.related.?.line);
    try std.testing.expectEqual(@as(u64, 4), diagnostic.related.?.byte_column);
}

test "[edge] - [attribute limits]: exact boundaries pass and one over fails" {
    var options: xml.OptionsFor(FAST_CONFIG) = .{};
    options.limits.max_attributes_per_element = 2;
    try expectSummarySchedulesWithOptions(FAST_CONFIG, options, "<r a='' b=''/>", .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 2,
        .attributes = 2,
        .attribute_name_bytes = 2,
    });
    try expectCoreFailureSchedulesWithOptions(
        options,
        "<r a='' b='' c=''/>",
        error.LimitExceeded,
        .attribute_count_limit,
        13,
        null,
    );

    options = .{};
    options.limits.max_attribute_name_bytes = 3;
    try expectSummarySchedulesWithOptions(FAST_CONFIG, options, "<r abc=''/>", .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 2,
        .attributes = 1,
        .attribute_name_bytes = 3,
    });
    try expectCoreFailureSchedulesWithOptions(
        options,
        "<r abcd=''/>",
        error.LimitExceeded,
        .attribute_name_limit,
        6,
        null,
    );

    options = .{};
    options.limits.max_attribute_value_bytes = 3;
    try expectSummarySchedulesWithOptions(FAST_CONFIG, options, "<r a='abc'/>", .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 2,
        .attributes = 1,
        .attribute_name_bytes = 1,
        .attribute_value_bytes = 3,
    });
    try expectCoreFailureSchedulesWithOptions(
        options,
        "<r a='abcd'/>",
        error.LimitExceeded,
        .attribute_value_limit,
        9,
        null,
    );

    options = .{};
    options.limits.max_attribute_bytes_per_element = 4;
    try expectSummarySchedulesWithOptions(FAST_CONFIG, options, "<r a='123'/>", .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 2,
        .attributes = 1,
        .attribute_name_bytes = 1,
        .attribute_value_bytes = 3,
    });
    try expectCoreFailureSchedulesWithOptions(
        options,
        "<r a='1234'/>",
        error.LimitExceeded,
        .attribute_bytes_limit,
        9,
        null,
    );

    options = .{};
    options.limits.max_start_tag_bytes = 10;
    try expectSummarySchedulesWithOptions(FAST_CONFIG, options, "<r a='x'/>", .{
        .sequence = 1234,
        .starts = 1,
        .ends = 1,
        .empty_starts = 1,
        .name_bytes = 2,
        .attributes = 1,
        .attribute_name_bytes = 1,
        .attribute_value_bytes = 1,
    });
    try expectCoreFailureSchedulesWithOptions(
        options,
        "<r a='xy'/>",
        error.LimitExceeded,
        .start_tag_limit,
        10,
        null,
    );
}

test "[edge] - [attribute limits]: specific limits win tied boundaries" {
    var options: xml.OptionsFor(FAST_CONFIG) = .{};
    options.limits.max_attribute_name_bytes = 1;
    options.limits.max_attribute_bytes_per_element = 1;
    try expectCoreFailure(
        options,
        "<r ab=''/>",
        error.LimitExceeded,
        .attribute_name_limit,
        4,
        null,
    );

    options = .{};
    options.limits.max_attribute_value_bytes = 1;
    options.limits.max_attribute_bytes_per_element = 2;
    try expectCoreFailure(
        options,
        "<r a='xy'/>",
        error.LimitExceeded,
        .attribute_value_limit,
        7,
        null,
    );

    options = .{};
    options.limits.max_attribute_bytes_per_element = 2;
    options.limits.max_start_tag_bytes = 7;
    try expectCoreFailureSchedulesWithOptions(
        options,
        "<r a='xy'/>",
        error.LimitExceeded,
        .attribute_bytes_limit,
        7,
        null,
    );
}

test "[failure] - [attribute limits]: excess bytes are not stored" {
    var options: xml.OptionsFor(FAST_CONFIG) = .{};
    options.limits.max_attribute_name_bytes = 3;
    const Reader = xml.ReaderFor(FAST_CONFIG);
    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<r abcd='value'/>", true);

    _ = try reader.next();
    try std.testing.expectError(error.LimitExceeded, reader.next());
    try std.testing.expectEqual(xml.DiagnosticCode.attribute_name_limit, reader.diagnostic().?.code);
    try std.testing.expectEqual(@as(u64, 6), reader.diagnostic().?.primary.byte_offset);
    try std.testing.expectEqual(@as(usize, 1), reader.memoryUsage().attribute_count);
    try std.testing.expectEqual(@as(usize, 3), reader.memoryUsage().attribute_bytes);
}

test "[failure] - [attribute storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationAttributeParse,
        .{},
    );
}

test "[unit] - [attribute lifetime]: storage remains active through the start event" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<root first='one' second=\"two\"/>", true);

    _ = try reader.next();
    const start_step = try reader.next();
    const attributes = switch (start_step) {
        .event => |event| switch (event) {
            .start_element => |start| start.attributes,
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };
    try std.testing.expectEqual(@as(usize, 2), attributes.len);
    try std.testing.expectEqualStrings("first", attributes[0].name.raw);
    try std.testing.expectEqualStrings("one", attributes[0].value);
    try std.testing.expectEqual(@as(usize, 2), reader.memoryUsage().attribute_count);
    try std.testing.expectEqual(@as(usize, 17), reader.memoryUsage().attribute_bytes);

    _ = try reader.next();
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_count);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_bytes);
    try std.testing.expect(reader.memoryUsage().attribute_record_capacity >= 2);
    try std.testing.expect(reader.memoryUsage().attribute_event_capacity >= 2);
    try std.testing.expect(reader.memoryUsage().scratch_capacity >= 17);

    try reader.reset(.retain_capacity);
    try reader.feed("<root key='value'/>", true);
    _ = try reader.next();
    _ = try reader.next();
    try std.testing.expectEqual(@as(usize, 1), reader.memoryUsage().attribute_count);
    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_count);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_bytes);
}

test "[unit] - [attribute storage]: warm fixed shape performs no allocator operation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader = try CoreReader.init(failing.allocator(), .{});
    defer reader.deinit();

    try reader.feed(MANY_ATTRIBUTES, true);
    try std.testing.expectEqual(@as(usize, 17), (try drainCore(&reader)).attributes);
    try std.testing.expect(failing.alloc_index > 0);

    try reader.reset(.retain_capacity);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try reader.feed(MANY_ATTRIBUTES, true);
    try std.testing.expectEqual(@as(usize, 17), (try drainCore(&reader)).attributes);
    try std.testing.expect(!failing.has_induced_failure);
}

test "reader - limits: partial name fails before consuming the excess byte" {
    var options: xml.OptionsFor(xml.Configs.XML10_UTF8_NO_DTD_FAST) = .{};
    options.limits.max_partial_token_bytes = 3;
    const Reader = xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD_FAST);
    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();

    try reader.feed("<root/>", true);
    _ = try reader.next();
    try std.testing.expectError(error.LimitExceeded, reader.next());
    try std.testing.expectEqual(xml.DiagnosticCode.partial_token_limit, reader.diagnostic().?.code);
    try std.testing.expectEqual(@as(u64, 4), reader.diagnostic().?.primary.byte_offset);
}

test "limit - closing name: partial-token limit precedes a later mismatch" {
    var options: xml.OptionsFor(FAST_CONFIG) = .{};
    options.limits.max_partial_token_bytes = 3;
    try expectCoreFailure(
        options,
        "<abc></abcd>",
        error.LimitExceeded,
        .partial_token_limit,
        10,
        null,
    );
}

test "limit - open elements: depth succeeds at the boundary and fails before growth" {
    var options: xml.OptionsFor(FAST_CONFIG) = .{};
    options.limits.max_depth = 2;

    {
        const Reader = xml.ReaderFor(FAST_CONFIG);
        var reader = try Reader.init(std.testing.allocator, options);
        defer reader.deinit();
        try reader.feed("<a><b/></a>", true);
        var sequence: u64 = 0;
        while (true) {
            switch (try reader.next()) {
                .event => |event| switch (event) {
                    .document_start => sequence = sequence * 10 + 1,
                    .start_element => sequence = sequence * 10 + 2,
                    .end_element => sequence = sequence * 10 + 3,
                    .document_end => sequence = sequence * 10 + 4,
                    else => return error.UnexpectedEvent,
                },
                .need_input => return error.UnexpectedNeedInput,
                .done => break,
            }
        }
        try std.testing.expectEqual(@as(u64, 122334), sequence);
    }

    try expectCoreFailure(
        options,
        "<a><b><c/></b></a>",
        error.LimitExceeded,
        .depth_limit,
        7,
        null,
    );

    const Reader = xml.ReaderFor(FAST_CONFIG);
    var limited = try Reader.init(std.testing.allocator, options);
    defer limited.deinit();
    try limited.feed("<a><b><c/></b></a>", true);
    while (true) {
        const step = limited.next() catch break;
        if (step == .done) return error.ExpectedFailure;
    }
    try std.testing.expectEqual(@as(usize, 2), limited.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 2), limited.memoryUsage().open_name_bytes);
}

test "limit - open names: cumulative active bytes succeed at limit and fail one over" {
    var at_limit: xml.OptionsFor(FAST_CONFIG) = .{};
    at_limit.limits.max_open_name_bytes = 5;
    try expectCoreFailure(
        at_limit,
        "<root><ab/></root>",
        error.LimitExceeded,
        .open_name_limit,
        8,
        null,
    );

    {
        const LimitedReader = xml.ReaderFor(FAST_CONFIG);
        var limited = try LimitedReader.init(std.testing.allocator, at_limit);
        defer limited.deinit();
        try limited.feed("<root><ab/></root>", true);
        while (true) {
            const step = limited.next() catch break;
            if (step == .done) return error.ExpectedFailure;
        }
        try std.testing.expectEqual(@as(usize, 1), limited.memoryUsage().parser_stack_len);
        try std.testing.expectEqual(@as(usize, 5), limited.memoryUsage().open_name_bytes);
    }

    const Reader = xml.ReaderFor(FAST_CONFIG);
    var reader = try Reader.init(std.testing.allocator, at_limit);
    defer reader.deinit();
    try reader.feed("<root><a/><b/><c/></root>", true);
    var summary: Summary = .{};
    while (true) {
        switch (try reader.next()) {
            .event => |event| try summary.observe(event),
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        }
    }
    try std.testing.expectEqual(@as(u64, 1223232334), summary.sequence);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().open_name_bytes);
}

test "limit - open names: partial-token precedence is stable when limits tie" {
    var options: xml.OptionsFor(FAST_CONFIG) = .{};
    options.limits.max_open_name_bytes = 3;
    options.limits.max_partial_token_bytes = 3;
    try expectCoreFailure(
        options,
        "<root/>",
        error.LimitExceeded,
        .partial_token_limit,
        4,
        null,
    );
}

test "lifetime - end event: frame and name reclamation is deferred until next call" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<root><child/></root>", true);

    _ = try reader.next();
    _ = try reader.next();
    const child_start = try reader.next();
    const child_name = switch (child_start) {
        .event => |event| switch (event) {
            .start_element => |start| start.name.raw,
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };
    try std.testing.expectEqualStrings("child", child_name);
    try std.testing.expectEqual(@as(usize, 2), reader.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 9), reader.memoryUsage().open_name_bytes);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().scratch_capacity);

    const child_end = try reader.next();
    switch (child_end) {
        .event => |event| switch (event) {
            .end_element => |end| try std.testing.expectEqualStrings("child", end.name.raw),
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    }
    try std.testing.expectEqualStrings("child", child_name);
    try std.testing.expectEqual(@as(usize, 2), reader.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 9), reader.memoryUsage().open_name_bytes);

    const root_end = try reader.next();
    switch (root_end) {
        .event => |event| switch (event) {
            .end_element => |end| try std.testing.expectEqualStrings("root", end.name.raw),
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    }
    try std.testing.expectEqual(@as(usize, 1), reader.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 4), reader.memoryUsage().open_name_bytes);

    _ = try reader.next();
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().open_name_bytes);
}

test "memory - failed parse: active storage is visible and reset policies clear it" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<root><item></root>", true);

    while (true) {
        const step = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        };
        if (step == .done) return error.ExpectedFailure;
    }
    try std.testing.expectEqual(@as(usize, 2), reader.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 8), reader.memoryUsage().open_name_bytes);
    const retained = reader.memoryUsage().retained_capacity;
    try std.testing.expect(retained > 0);

    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().parser_stack_len);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().open_name_bytes);
    try std.testing.expectEqual(retained, reader.memoryUsage().retained_capacity);

    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
}

test "[failure] - [attribute storage]: failed parse reset clears active bytes and records" {
    var reader = try CoreReader.init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<root first='one' second='two' first='three'/>", true);

    while (true) {
        const step = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        };
        if (step == .done) return error.ExpectedFailure;
    }
    const usage = reader.memoryUsage();
    try std.testing.expectEqual(@as(usize, 3), usage.attribute_count);
    try std.testing.expectEqual(@as(usize, 27), usage.attribute_bytes);
    try std.testing.expect(usage.scratch_capacity >= usage.attribute_bytes);
    try std.testing.expect(usage.retained_capacity > 0);

    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_count);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_bytes);
    try std.testing.expectEqual(usage.retained_capacity, reader.memoryUsage().retained_capacity);

    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
}

test "allocation - open storage: every allocation failure is cleaned up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationParse,
        .{},
    );
}

test "allocation - open storage: arena and frame failures permit reset and deinit" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var reader = try CoreReader.init(failing.allocator(), .{});
        try reader.feed("<root/>", true);

        var saw_out_of_memory = false;
        while (true) {
            const step = reader.next() catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                saw_out_of_memory = true;
                break;
            };
            switch (step) {
                .event => {},
                .need_input => return error.UnexpectedNeedInput,
                .done => break,
            }
        }
        try std.testing.expect(saw_out_of_memory);
        try reader.reset(.release_memory);
        try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
        reader.deinit();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "reader - retained capacity: warm nested parse performs no allocator operation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader = try CoreReader.init(failing.allocator(), .{});
    defer reader.deinit();

    try reader.feed("<root><item/><group><leaf/></group></root>", true);
    try std.testing.expectEqual(@as(u64, 1223223334), (try drainCore(&reader)).sequence);
    try std.testing.expect(failing.alloc_index > 0);

    try reader.reset(.retain_capacity);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try reader.feed("<root><item/><group><leaf/></group></root>", true);
    try std.testing.expectEqual(@as(u64, 1223223334), (try drainCore(&reader)).sequence);
    try std.testing.expect(!failing.has_induced_failure);
}

test "reader - retained ceiling: retain reset releases exceptional capacity" {
    var options: xml.OptionsFor(CORE_CONFIG) = .{};
    options.limits.max_retained_bytes = 1;
    var reader = try CoreReader.init(std.testing.allocator, options);
    defer reader.deinit();

    try reader.feed(MANY_ATTRIBUTES, true);
    _ = try drainCore(&reader);
    try std.testing.expect(reader.memoryUsage().retained_capacity > 1);
    try std.testing.expect(reader.memoryUsage().attribute_record_capacity >= 17);
    try std.testing.expect(reader.memoryUsage().attribute_event_capacity >= 17);

    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
}

test "[edge] - [retained capacity]: exact boundary retains and one below releases" {
    const retained = retained: {
        var probe = try CoreReader.init(std.testing.allocator, .{});
        defer probe.deinit();
        try probe.feed(MANY_ATTRIBUTES, true);
        _ = try drainCore(&probe);
        break :retained probe.memoryUsage().retained_capacity;
    };
    try std.testing.expect(retained > 0);

    var at_options: xml.OptionsFor(CORE_CONFIG) = .{};
    at_options.limits.max_retained_bytes = retained;
    var at = try CoreReader.init(std.testing.allocator, at_options);
    defer at.deinit();
    try at.feed(MANY_ATTRIBUTES, true);
    _ = try drainCore(&at);
    try std.testing.expectEqual(retained, at.memoryUsage().retained_capacity);
    try at.reset(.retain_capacity);
    try std.testing.expectEqual(retained, at.memoryUsage().retained_capacity);

    var over_options: xml.OptionsFor(CORE_CONFIG) = .{};
    over_options.limits.max_retained_bytes = retained - 1;
    var over = try CoreReader.init(std.testing.allocator, over_options);
    defer over.deinit();
    try over.feed(MANY_ATTRIBUTES, true);
    _ = try drainCore(&over);
    try std.testing.expectEqual(retained, over.memoryUsage().retained_capacity);
    try over.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), over.memoryUsage().retained_capacity);
}

test "[property] - [reader schedules]: generated valid shapes agree across schedules" {
    var input_buffer: [4096]u8 = undefined;
    for (0..128) |case_index| {
        var output = std.Io.Writer.fixed(&input_buffer);
        const children = case_index % 6;
        try output.print("<root case='{d}'>", .{case_index});
        for (0..children) |child| {
            try output.print("<item id='{d}'>value&amp;{d}</item>", .{ child, case_index });
        }
        try output.writeAll("</root>");
        const input = output.buffered();
        const parts = [_][]const u8{input};
        const whole = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        var expected_text_buffer: [256]u8 = undefined;
        var expected_text = std.Io.Writer.fixed(&expected_text_buffer);
        for (0..children) |_| try expected_text.print("value&{d}", .{case_index});
        try std.testing.expectEqual(children + 1, whole.starts);
        try std.testing.expectEqual(children + 1, whole.ends);
        try std.testing.expectEqual(children + 1, whole.attributes);
        try std.testing.expectEqualStrings(
            expected_text.buffered(),
            whole.text_bytes[0..whole.text_bytes_len],
        );
        try std.testing.expectEqual(
            whole,
            try parseOneByteChunks(CORE_CONFIG, std.testing.allocator, .{}, input),
        );
        try std.testing.expectEqual(
            whole,
            try parseFixedChunks(CORE_CONFIG, std.testing.allocator, .{}, input, 31),
        );
        try std.testing.expectEqual(
            whole,
            try parseRandomChunks(CORE_CONFIG, std.testing.allocator, .{}, input, case_index),
        );
    }
}

test "[property] - [persistent reader]: success failure limit and resets remain bounded" {
    var options: xml.OptionsFor(CORE_CONFIG) = .{};
    options.limits.max_attributes_per_element = 2;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var reader = try CoreReader.init(failing.allocator(), options);
        defer reader.deinit();

        var plateau: usize = 0;
        var samples_since_release: usize = 0;
        for (0..1024) |iteration| {
            const input = switch (iteration % 3) {
                0 => "<root a='1' b='2'><item/></root>",
                1 => "<root><item></root>",
                else => "<root a='1' b='2' c='3'/>",
            };
            try reader.feed(input, true);
            const wanted_error: ?anyerror = switch (iteration % 3) {
                0 => null,
                1 => error.InvalidXml,
                else => error.LimitExceeded,
            };
            var observed_error: ?anyerror = null;
            while (true) {
                const step = reader.next() catch |err| {
                    observed_error = err;
                    break;
                };
                if (step == .done) break;
                if (step == .need_input) return error.UnexpectedNeedInput;
            }
            try std.testing.expectEqual(wanted_error, observed_error);
            const retained = reader.memoryUsage().retained_capacity;
            if (samples_since_release < 3) {
                plateau = @max(plateau, retained);
            } else {
                try std.testing.expect(retained <= plateau);
            }
            samples_since_release += 1;

            if (iteration % 127 == 126) {
                try reader.reset(.release_memory);
                try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
                plateau = 0;
                samples_since_release = 0;
            } else {
                try reader.reset(.retain_capacity);
                try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().parser_stack_len);
                try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().attribute_count);
                try std.testing.expect(reader.memoryUsage().retained_capacity <= plateau);
            }
        }
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

const FuzzOutcome = struct {
    disposition: enum { accept, invalid, unsupported, limit },
    code: ?xml.DiagnosticCode = null,
    offset: u64 = 0,
    starts: usize = 0,
    ends: usize = 0,
    attributes: usize = 0,
    text_bytes: usize = 0,
};

fn arbitraryOutcome(comptime config: xml.Config, input: []const u8, seed: ?u64) !FuzzOutcome {
    var options: xml.OptionsFor(config) = .{};
    options.limits.max_depth = 16;
    options.limits.max_open_name_bytes = 256;
    options.limits.max_partial_token_bytes = 256;
    options.limits.max_attributes_per_element = 16;
    options.limits.max_attribute_name_bytes = 128;
    options.limits.max_attribute_value_bytes = 256;
    options.limits.max_attribute_bytes_per_element = 512;
    options.limits.max_start_tag_bytes = 512;
    options.limits.max_fragment_bytes = 64;
    options.limits.max_processing_instruction_target_bytes = 64;
    options.limits.max_retained_bytes = 512;
    if (comptime @hasField(@TypeOf(options.dtd_limits), "max_dtd_bytes")) {
        options.dtd_limits.max_dtd_bytes = 512;
        options.dtd_limits.max_declarations = 32;
        options.dtd_limits.max_entity_replacement_bytes = 512;
        options.dtd_limits.max_entity_references = 128;
        options.dtd_limits.max_expanded_bytes = 4096;
        options.dtd_limits.expansion_ratio_minimum_bytes = 256;
        options.dtd_limits.max_comparison_work = 4096;
    }

    const Reader = xml.ReaderFor(config);
    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();
    var outcome: FuzzOutcome = .{ .disposition = .accept };
    var prng = std.Random.DefaultPrng.init(seed orelse 0);
    const random = prng.random();
    var offset: usize = 0;
    var steps: usize = 0;

    while (offset < input.len or input.len == 0) {
        const end = if (input.len == 0)
            0
        else if (seed == null)
            input.len
        else
            offset + random.intRangeAtMost(usize, 1, @min(@as(usize, 17), input.len - offset));
        try reader.feed(input[offset..end], end == input.len);
        offset = end;
        while (true) {
            steps += 1;
            if (steps > input.len * 3 + 16) return error.NonTerminatingParser;
            const step = reader.next() catch |err| {
                const diagnostic = reader.diagnostic();
                return switch (err) {
                    error.InvalidXml => .{
                        .disposition = .invalid,
                        .code = diagnostic.?.code,
                        .offset = diagnostic.?.primary.byte_offset,
                    },
                    error.UnsupportedFeature => .{
                        .disposition = .unsupported,
                        .code = diagnostic.?.code,
                        .offset = diagnostic.?.primary.byte_offset,
                    },
                    error.LimitExceeded => .{
                        .disposition = .limit,
                        .code = diagnostic.?.code,
                        .offset = diagnostic.?.primary.byte_offset,
                    },
                    else => err,
                };
            };
            switch (step) {
                .event => |event| switch (event) {
                    .start_element => |start| {
                        outcome.starts += 1;
                        outcome.attributes += start.attributes.len;
                    },
                    .end_element => outcome.ends += 1,
                    .text => |text| outcome.text_bytes += text.bytes.len,
                    else => {},
                },
                .need_input => break,
                .done => return outcome,
            }
        }
        if (input.len == 0) unreachable;
    }
    return error.MissingDone;
}

fn fuzzArbitraryBytes(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [512]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    inline for (.{ FAST_CONFIG, GENERAL_FAST_CONFIG, DTD_CONFIG, DTD_NS_CONFIG }) |config| {
        const whole = try arbitraryOutcome(config, input, null);
        try std.testing.expectEqual(
            whole,
            try arbitraryOutcome(config, input, 0x7a786d6c),
        );
    }
}

test "[fuzz] - [arbitrary bytes]: parsing is bounded and schedule invariant" {
    try std.testing.fuzz({}, fuzzArbitraryBytes, .{
        .corpus = &.{
            "<root/>",
            "<root a='&amp;'>text</root>",
            "<root><item></root>",
            "<!DOCTYPE root><root/>",
            "<!DOCTYPE root [<!ENTITY text 'value'>]><root>&text;</root>",
            "<!DOCTYPE root [<!ENTITY loop '&loop;'>]><root>&loop;</root>",
            "\xef\xbb\xbf<root>\xf0\x9f\x99\x82</root>",
            "<root>\xc0\x80</root>",
            UTF16LE_BOM,
            UTF16LE_ODD_BYTE,
            UTF16LE_UNPAIRED_HIGH,
            UTF16BE_UNPAIRED_LOW,
        },
    });
}

test "[property] - [arbitrary bytes]: deterministic campaign is bounded and schedule invariant" {
    var prng = std.Random.DefaultPrng.init(0x737461676537);
    const random = prng.random();
    var storage: [512]u8 = undefined;
    for (0..10_000) |iteration| {
        const len = random.intRangeAtMost(usize, 0, storage.len);
        random.bytes(storage[0..len]);
        inline for (.{ FAST_CONFIG, GENERAL_FAST_CONFIG, DTD_CONFIG, DTD_NS_CONFIG }) |config| {
            const whole = try arbitraryOutcome(config, storage[0..len], null);
            try std.testing.expectEqual(
                whole,
                try arbitraryOutcome(config, storage[0..len], iteration + 1),
            );
        }
    }
}

test "[regression] - [source refill]: malformed UTF-8 offset survives refill" {
    inline for (.{ FAST_CONFIG, GENERAL_FAST_CONFIG }) |config| {
        const Reader = xml.ReaderFor(config);
        var reader = try Reader.init(std.testing.allocator, .{});
        defer reader.deinit();
        try reader.feed("<?\xe9\xa5", false);
        while (true) switch (try reader.next()) {
            .event => {},
            .need_input => break,
            .done => return error.UnexpectedDone,
        };
        try reader.feed("p", true);
        try std.testing.expectError(error.InvalidXml, reader.next());
        try std.testing.expectEqual(xml.DiagnosticCode.malformed_utf8, reader.diagnostic().?.code);
        try std.testing.expectEqual(@as(u64, 4), reader.diagnostic().?.primary.byte_offset);
    }
}

test "[failure] - [reader initialization]: zero required limits fail without allocation" {
    const Reader = xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD);
    var options: xml.OptionsFor(xml.Configs.XML10_UTF8_NO_DTD) = .{};
    options.limits.max_depth = 0;

    try std.testing.expectError(error.InvalidOptions, Reader.init(std.testing.allocator, options));

    options = .{};
    options.limits.max_open_name_bytes = 0;
    try std.testing.expectError(error.InvalidOptions, Reader.init(std.testing.allocator, options));

    inline for (.{
        "max_attributes_per_element",
        "max_partial_token_bytes",
        "max_attribute_name_bytes",
        "max_attribute_value_bytes",
        "max_attribute_bytes_per_element",
        "max_start_tag_bytes",
        "max_fragment_bytes",
        "max_processing_instruction_target_bytes",
    }) |field_name| {
        options = .{};
        @field(options.limits, field_name) = 0;
        try std.testing.expectError(error.InvalidOptions, Reader.init(std.testing.allocator, options));
    }

    const NamespaceReader = xml.ReaderFor(NS_CONFIG);
    var namespace_options: xml.OptionsFor(NS_CONFIG) = .{};
    inline for (.{
        "max_declarations_per_element",
        "max_active_bindings",
        "max_binding_bytes",
        "max_qname_bytes",
        "max_comparison_work",
    }) |field_name| {
        namespace_options = .{};
        @field(namespace_options.namespace_limits, field_name) = 0;
        try std.testing.expectError(
            error.InvalidOptions,
            NamespaceReader.init(std.testing.allocator, namespace_options),
        );
    }

    const DtdReader = xml.ReaderFor(xml.Configs.XML10_NONVALIDATING);
    var dtd_options: xml.OptionsFor(xml.Configs.XML10_NONVALIDATING) = .{};
    inline for (.{
        "max_dtd_bytes",
        "max_declarations",
        "max_declaration_bytes",
        "max_element_declarations",
        "max_attribute_declarations",
        "max_entity_declarations",
        "max_notation_declarations",
        "max_group_depth",
        "max_grammar_nodes",
        "max_entity_replacement_bytes",
        "max_active_entity_depth",
        "max_entity_references",
        "max_expanded_bytes",
        "max_expansion_ratio",
        "max_comparison_work",
    }) |field_name| {
        dtd_options = .{};
        @field(dtd_options.dtd_limits, field_name) = 0;
        try std.testing.expectError(
            error.InvalidOptions,
            DtdReader.init(std.testing.allocator, dtd_options),
        );
    }

    const ValidatingReader = xml.ReaderFor(xml.Configs.XML10_VALIDATING);
    var validating_options: xml.OptionsFor(xml.Configs.XML10_VALIDATING) = .{};
    inline for (.{
        "max_content_positions",
        "max_content_states",
        "max_content_transitions",
        "max_compilation_work",
        "max_ids",
        "max_idrefs",
        "max_id_bytes",
        "max_comparison_work",
        "max_errors",
    }) |field_name| {
        validating_options = .{};
        @field(validating_options.validation.limits, field_name) = 0;
        try std.testing.expectError(
            error.InvalidOptions,
            ValidatingReader.init(std.testing.allocator, validating_options),
        );
    }
    validating_options = .{};
    validating_options.validation.limits.max_content_positions = std.math.maxInt(usize);
    try std.testing.expectError(
        error.InvalidOptions,
        ValidatingReader.init(std.testing.allocator, validating_options),
    );
    validating_options = .{};
    validating_options.validation.limits.max_content_transitions = std.math.maxInt(usize);
    try std.testing.expectError(
        error.InvalidOptions,
        ValidatingReader.init(std.testing.allocator, validating_options),
    );
}

test "[edge] - [validation limits]: report the exact exhausted resource" {
    const config = xml.Configs.XML10_VALIDATING;
    const LimitCase = enum {
        content_positions,
        content_states,
        content_transitions,
        compilation_work,
        ids,
        idrefs,
        identity_bytes,
        comparison_work,
    };
    const cases = [_]struct {
        kind: LimitCase,
        input: []const u8,
        code: xml.DiagnosticCode,
    }{
        .{
            .kind = .content_positions,
            .input = "<!DOCTYPE root [<!ELEMENT root (a,b)><!ELEMENT a EMPTY><!ELEMENT b EMPTY>]><root><a/><b/></root>",
            .code = .validation_content_position_limit,
        },
        .{
            .kind = .content_states,
            .input = "<!DOCTYPE root [<!ELEMENT root (a)><!ELEMENT a EMPTY>]><root><a/></root>",
            .code = .validation_content_state_limit,
        },
        .{
            .kind = .content_transitions,
            .input = "<!DOCTYPE root [<!ELEMENT root (a,b)><!ELEMENT a EMPTY><!ELEMENT b EMPTY>]><root><a/><b/></root>",
            .code = .validation_content_transition_limit,
        },
        .{
            .kind = .compilation_work,
            .input = "<!DOCTYPE root [<!ELEMENT root (a)><!ELEMENT a EMPTY>]><root><a/></root>",
            .code = .validation_compilation_work_limit,
        },
        .{
            .kind = .ids,
            .input = "<!DOCTYPE root [<!ELEMENT root (item,item)><!ELEMENT item EMPTY><!ATTLIST item id ID #REQUIRED>]><root><item id='a'/><item id='b'/></root>",
            .code = .validation_id_limit,
        },
        .{
            .kind = .idrefs,
            .input = "<!DOCTYPE root [<!ELEMENT root (item)><!ELEMENT item EMPTY><!ATTLIST item refs IDREFS #IMPLIED>]><root><item refs='a b'/></root>",
            .code = .validation_idref_limit,
        },
        .{
            .kind = .identity_bytes,
            .input = "<!DOCTYPE root [<!ELEMENT root (item)><!ELEMENT item EMPTY><!ATTLIST item id ID #REQUIRED>]><root><item id='aa'/></root>",
            .code = .validation_identity_bytes_limit,
        },
        .{
            .kind = .comparison_work,
            .input = "<!DOCTYPE root [<!ELEMENT root EMPTY>]><root/>",
            .code = .validation_comparison_work_limit,
        },
    };

    for (cases) |case| {
        var options: xml.OptionsFor(config) = .{};
        switch (case.kind) {
            .content_positions => options.validation.limits.max_content_positions = 1,
            .content_states => options.validation.limits.max_content_states = 1,
            .content_transitions => options.validation.limits.max_content_transitions = 1,
            .compilation_work => options.validation.limits.max_compilation_work = 1,
            .ids => options.validation.limits.max_ids = 1,
            .idrefs => options.validation.limits.max_idrefs = 1,
            .identity_bytes => options.validation.limits.max_id_bytes = 1,
            .comparison_work => options.validation.limits.max_comparison_work = 1,
        }
        var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
        defer reader.deinit();
        try reader.feed(case.input, true);
        while (true) {
            const result = reader.next() catch |err| {
                try std.testing.expectEqual(error.LimitExceeded, err);
                try std.testing.expectEqual(case.code, reader.diagnostic().?.code);
                break;
            };
            switch (result) {
                .event => {},
                .done => return error.ExpectedLimitFailure,
                .need_input => return error.UnexpectedNeedInput,
            }
        }
    }
}

test "[edge] - [validation limits]: nested operators preserve the position boundary" {
    const config = xml.Configs.XML10_VALIDATING;
    var options: xml.OptionsFor(config) = .{};
    options.validation.limits.max_content_positions = 1;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [" ++
            "<!ELEMENT root (((a?)?)?)>" ++
            "<!ELEMENT a EMPTY>" ++
            "]><root/>",
        true,
    );

    var status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .document_end => |end| status = end.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };
    try std.testing.expectEqual(xml.ProfileValidationStatus.valid, status.?);
}

test "[unit] - [namespace expansion]: declarations and ordinary attributes are distinct" {
    const input =
        "<root xmlns=\"urn:elements\" attribute=\"no-namespace\" " ++
        "xmlns:p=\"urn:attributes\" p:attribute=\"namespaced\"/>\n";
    const Reader = xml.ProfileSliceReader(NS_CONFIG);
    var reader = try Reader.init(std.testing.allocator, .{}, input);
    defer reader.deinit();

    _ = try reader.next();
    const start = switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |value| value,
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };
    try expectExpandedName(start.name, "root", null, "root", "urn:elements");
    try std.testing.expectEqual(@as(usize, 2), start.namespace_declarations.len);
    try std.testing.expect(start.namespace_declarations[0].prefix == null);
    try std.testing.expectEqualStrings(
        "urn:elements",
        start.namespace_declarations[0].namespace_uri,
    );
    try std.testing.expectEqualStrings("p", start.namespace_declarations[1].prefix.?);
    try std.testing.expectEqualStrings(
        "urn:attributes",
        start.namespace_declarations[1].namespace_uri,
    );
    try std.testing.expectEqual(@as(usize, 2), start.attributes.len);
    try expectExpandedName(start.attributes[0].name, "attribute", null, "attribute", null);
    try expectExpandedName(
        start.attributes[1].name,
        "p:attribute",
        "p",
        "attribute",
        "urn:attributes",
    );
}

test "[unit] - [namespace event lifetime]: slices survive source-buffer reuse" {
    var input: [32]u8 = undefined;
    var reader = try xml.ReaderFor(NS_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();

    const first = "<p:r xmlns:p='urn:";
    @memcpy(input[0..first.len], first);
    try reader.feed(input[0..first.len], false);
    _ = try reader.next();
    switch (try reader.next()) {
        .need_input => {},
        else => return error.UnexpectedStep,
    }

    const second = "&#x70;' p:a='v'";
    @memcpy(input[0..second.len], second);
    try reader.feed(input[0..second.len], false);
    switch (try reader.next()) {
        .need_input => {},
        else => return error.UnexpectedStep,
    }

    const final = "/>";
    @memcpy(input[0..final.len], final);
    try reader.feed(input[0..final.len], true);
    const start = switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |value| value,
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };

    try expectExpandedName(start.name, "p:r", "p", "r", "urn:p");
    try std.testing.expectEqual(@as(usize, 1), start.namespace_declarations.len);
    try std.testing.expectEqualStrings("p", start.namespace_declarations[0].prefix.?);
    try std.testing.expectEqualStrings("urn:p", start.namespace_declarations[0].namespace_uri);
    try std.testing.expectEqual(@as(usize, 1), start.attributes.len);
    try expectExpandedName(start.attributes[0].name, "p:a", "p", "a", "urn:p");
    try std.testing.expectEqualStrings("v", start.attributes[0].value);

    switch (try reader.next()) {
        .event => |event| switch (event) {
            .end_element => |end| try expectExpandedName(end.name, "p:r", "p", "r", "urn:p"),
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    }
}

test "[unit] - [namespace scope]: rebinding undeclaration and predefined xml resolve exactly" {
    const rebinding =
        "<root xmlns:p=\"urn:outer\"><p:item/><scope xmlns:p=\"urn:inner\">" ++
        "<p:item/></scope><p:item/></root>\n";
    const default_undeclaration =
        "<root xmlns=\"urn:outer\"><child xmlns=\"\"><leaf/></child></root>\n";
    const inputs = [_][]const u8{
        rebinding,
        default_undeclaration,
        "<root xml:lang=\"en\" xml:space=\"preserve\"> text </root>\n",
        "<root xmlns:a=\"urn:example&amp;value\" xmlns:b=\"urn:example&#38;value\">" ++
            "<a:item/><b:item/></root>\n",
    };
    for (inputs) |input| {
        const parts = [_][]const u8{input};
        _ = try parseParts(NS_CONFIG, std.testing.allocator, .{}, &parts);
    }

    var reader = try xml.ProfileSliceReader(NS_CONFIG).init(
        std.testing.allocator,
        .{},
        rebinding,
    );
    defer reader.deinit();
    var item_index: usize = 0;
    var end_item_index: usize = 0;
    const expected_uris = [_][]const u8{ "urn:outer", "urn:inner", "urn:outer" };
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| if (std.mem.eql(u8, start.name.raw, "p:item")) {
                try std.testing.expectEqualStrings(
                    expected_uris[item_index],
                    start.name.namespace_uri.?,
                );
                item_index += 1;
            },
            .end_element => |end| if (std.mem.eql(u8, end.name.raw, "p:item")) {
                try std.testing.expectEqualStrings(
                    expected_uris[end_item_index],
                    end.name.namespace_uri.?,
                );
                end_item_index += 1;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(expected_uris.len, item_index);
    try std.testing.expectEqual(expected_uris.len, end_item_index);

    var undeclare_reader = try xml.ProfileSliceReader(NS_CONFIG).init(
        std.testing.allocator,
        .{},
        default_undeclaration,
    );
    defer undeclare_reader.deinit();
    var start_index: usize = 0;
    var end_index: usize = 0;
    while (true) switch (try undeclare_reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| {
                if (start_index == 0) {
                    try expectExpandedName(start.name, "root", null, "root", "urn:outer");
                } else {
                    try std.testing.expect(start.name.namespace_uri == null);
                }
                start_index += 1;
            },
            .end_element => |end| {
                if (end_index == 2) {
                    try expectExpandedName(end.name, "root", null, "root", "urn:outer");
                } else {
                    try std.testing.expect(end.name.namespace_uri == null);
                }
                end_index += 1;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 3), start_index);
    try std.testing.expectEqual(@as(usize, 3), end_index);

    var options: xml.OptionsFor(NS_CONFIG) = .{};
    options.namespace_limits.max_active_bindings = 1;
    options.namespace_limits.max_binding_bytes = 2;
    var static_reader = try xml.ReaderFor(NS_CONFIG).init(std.testing.allocator, options);
    defer static_reader.deinit();
    try static_reader.feed(
        "<r xmlns:xml='http://www.w3.org/XML/1998/namespace' xmlns:p='u' xml:lang='en'/>",
        true,
    );
    _ = try static_reader.next();
    const static_start = switch (try static_reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| start,
            else => return error.UnexpectedEvent,
        },
        else => return error.UnexpectedStep,
    };
    try std.testing.expectEqual(@as(usize, 2), static_start.namespace_declarations.len);
    try std.testing.expectEqualStrings(
        "xml",
        static_start.namespace_declarations[0].prefix.?,
    );
    try std.testing.expectEqualStrings("p", static_start.namespace_declarations[1].prefix.?);
    try std.testing.expectEqual(@as(usize, 1), static_reader.memoryUsage().namespace_binding_count);
    try std.testing.expectEqual(@as(usize, 2), static_reader.memoryUsage().namespace_bytes);
    try expectExpandedName(
        static_start.attributes[0].name,
        "xml:lang",
        "xml",
        "lang",
        "http://www.w3.org/XML/1998/namespace",
    );
}

test "[unit] - [namespace normalization]: reference-expanded URI values resolve exactly" {
    const input =
        "<root xmlns:a=\"urn:example&amp;value\" xmlns:b=\"urn:example&#38;value\">" ++
        "<a:item/><b:item/></root>\n";
    var reader = try xml.ProfileSliceReader(NS_CONFIG).init(
        std.testing.allocator,
        .{},
        input,
    );
    defer reader.deinit();

    var declaration_count: usize = 0;
    var item_count: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| {
                for (start.namespace_declarations) |declaration| {
                    try std.testing.expectEqualStrings(
                        "urn:example&value",
                        declaration.namespace_uri,
                    );
                    declaration_count += 1;
                }
                if (std.mem.eql(u8, start.name.local, "item")) {
                    try std.testing.expectEqualStrings(
                        "urn:example&value",
                        start.name.namespace_uri.?,
                    );
                    item_count += 1;
                }
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 2), declaration_count);
    try std.testing.expectEqual(@as(usize, 2), item_count);
}

test "[property] - [namespace processing]: valid forms agree across schedules" {
    inline for (.{
        "<root xmlns=\"urn:example:default\"><child/></root>\n",
        "<p:root xmlns:p=\"urn:example:p\"><p:child p:attribute=\"value\"/></p:root>\n",
        "<root xmlns:p=\"urn:outer\"><p:item/><scope xmlns:p=\"urn:inner\">" ++
            "<p:item/></scope><p:item/></root>\n",
        "<root xmlns=\"urn:elements\" attribute=\"no-namespace\" " ++
            "xmlns:p=\"urn:attributes\" p:attribute=\"namespaced\"/>\n",
        "<root xml:lang=\"en\" xml:space=\"preserve\"> text </root>\n",
        "<root xmlns=\"urn:outer\"><child xmlns=\"\"><leaf/></child></root>\n",
        "<root xmlns:a=\"urn:example&amp;value\" xmlns:b=\"urn:example&#38;value\">" ++
            "<a:item/><b:item/></root>\n",
        NAMESPACE_CHURN_INPUT,
    }) |input| {
        const parts = [_][]const u8{input};
        const expected = try parseParts(NS_CONFIG, std.testing.allocator, .{}, &parts);
        try expectSummarySchedulesWithOptions(NS_CONFIG, .{}, input, expected);
    }
}

test "[failure] - [namespace processing]: invalid forms have stable diagnostics across schedules" {
    const Case = struct {
        input: []const u8,
        code: xml.DiagnosticCode,
        primary: usize,
        related: ?usize = null,
    };
    const bad_xml_binding = "<root xmlns:xml=\"urn:not-the-xml-namespace\"/>\n";
    const bad_xmlns_binding = "<root xmlns:xmlns=\"urn:not-allowed\"/>\n";
    const duplicate_expanded =
        "<root xmlns:a=\"urn:same\" xmlns:b=\"urn:same\" " ++
        "a:value=\"one\" b:value=\"two\"/>\n";
    const prefix_undeclaration =
        "<root xmlns:p=\"urn:p\"><child xmlns:p=\"\"/></root>\n";
    const bad_default_uri = "<root xmlns=\"http://www.w3.org/2000/xmlns/\"/>\n";
    const cases = [_]Case{
        .{ .input = "<p:root/>\n", .code = .unbound_prefix, .primary = 1 },
        .{ .input = "<root p:attribute=\"value\"/>\n", .code = .unbound_prefix, .primary = 6 },
        .{
            .input = bad_xml_binding,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.indexOf(u8, bad_xml_binding, "xmlns:xml").?,
        },
        .{
            .input = bad_xmlns_binding,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.indexOf(u8, bad_xmlns_binding, "xmlns:xmlns").?,
        },
        .{ .input = "<xmlns:root/>\n", .code = .reserved_namespace_name, .primary = 1 },
        .{
            .input = duplicate_expanded,
            .code = .duplicate_expanded_attribute,
            .primary = std.mem.indexOf(u8, duplicate_expanded, "b:value").?,
            .related = std.mem.indexOf(u8, duplicate_expanded, "a:value").?,
        },
        .{ .input = "<a:b:c xmlns:a=\"urn:a\"/>\n", .code = .malformed_qname, .primary = 4 },
        .{
            .input = prefix_undeclaration,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.lastIndexOf(u8, prefix_undeclaration, "xmlns:p").?,
        },
        .{
            .input = bad_default_uri,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.indexOf(u8, bad_default_uri, "xmlns").?,
        },
    };
    for (cases) |case| {
        try expectProfileFailureSchedules(
            NS_CONFIG,
            .{},
            case.input,
            error.InvalidXml,
            case.code,
            case.primary,
            case.related,
        );
    }
}

test "[failure] - [namespace precedence]: raw duplicates declarations and expansion fail in order" {
    const raw_duplicate = "<r xmlns:a='u' a:x='1' a:x='2'/>";
    try expectProfileFailureSchedules(
        NS_CONFIG,
        .{},
        raw_duplicate,
        error.InvalidXml,
        .duplicate_attribute,
        std.mem.lastIndexOf(u8, raw_duplicate, "a:x").?,
        std.mem.indexOf(u8, raw_duplicate, "a:x").?,
    );

    const declaration_before_unbound = "<p:r xmlns:xml='bad'/>";
    try expectProfileFailureSchedules(
        NS_CONFIG,
        .{},
        declaration_before_unbound,
        error.InvalidXml,
        .illegal_namespace_declaration,
        std.mem.indexOf(u8, declaration_before_unbound, "xmlns:xml").?,
        null,
    );
}

test "[failure] - [namespace storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationNamespaceParse,
        .{},
    );
}

test "[edge] - [namespace limits]: each boundary accepts at limit and rejects one over" {
    {
        const input = "<r xmlns:a='u' xmlns:b='v'/>";
        var options: xml.OptionsFor(NS_CONFIG) = .{};
        options.namespace_limits.max_declarations_per_element = 2;
        const parts = [_][]const u8{input};
        _ = try parseParts(NS_CONFIG, std.testing.allocator, options, &parts);
        options.namespace_limits.max_declarations_per_element = 1;
        try expectProfileFailureSchedules(
            NS_CONFIG,
            options,
            input,
            error.LimitExceeded,
            .namespace_declaration_limit,
            std.mem.indexOf(u8, input, "xmlns:b").?,
            null,
        );
    }
    {
        const input = "<r xmlns:a='u'><c xmlns:b='v'/></r>";
        var options: xml.OptionsFor(NS_CONFIG) = .{};
        options.namespace_limits.max_active_bindings = 2;
        const parts = [_][]const u8{input};
        _ = try parseParts(NS_CONFIG, std.testing.allocator, options, &parts);
        options.namespace_limits.max_active_bindings = 1;
        try expectProfileFailureSchedules(
            NS_CONFIG,
            options,
            input,
            error.LimitExceeded,
            .namespace_binding_limit,
            std.mem.indexOf(u8, input, "xmlns:b").?,
            null,
        );
    }
    {
        const input = "<r xmlns:a='urn'/>";
        var options: xml.OptionsFor(NS_CONFIG) = .{};
        options.namespace_limits.max_binding_bytes = 4;
        const parts = [_][]const u8{input};
        _ = try parseParts(NS_CONFIG, std.testing.allocator, options, &parts);
        options.namespace_limits.max_binding_bytes = 3;
        try expectProfileFailureSchedules(
            NS_CONFIG,
            options,
            input,
            error.LimitExceeded,
            .namespace_binding_bytes_limit,
            std.mem.indexOf(u8, input, "xmlns:a").?,
            null,
        );
    }
    {
        const input = "<root></root>";
        var options: xml.OptionsFor(NS_CONFIG) = .{};
        options.namespace_limits.max_qname_bytes = 4;
        const parts = [_][]const u8{input};
        _ = try parseParts(NS_CONFIG, std.testing.allocator, options, &parts);
        options.namespace_limits.max_qname_bytes = 3;
        try expectProfileFailureSchedules(
            NS_CONFIG,
            options,
            input,
            error.LimitExceeded,
            .qname_limit,
            4,
            null,
        );
    }
    {
        const input = "<r></root>";
        var options: xml.OptionsFor(NS_CONFIG) = .{};
        options.namespace_limits.max_qname_bytes = 3;
        try expectProfileFailureSchedules(
            NS_CONFIG,
            options,
            input,
            error.LimitExceeded,
            .qname_limit,
            8,
            null,
        );
    }
    {
        const input = "<r></🙂>";
        var options: xml.OptionsFor(NS_CONFIG) = .{};
        options.namespace_limits.max_qname_bytes = 3;
        try expectProfileFailureSchedules(
            NS_CONFIG,
            options,
            input,
            error.LimitExceeded,
            .qname_limit,
            5,
            null,
        );
    }
    {
        const input = "<r xmlns:a='u' a:x='1'/>";
        var options: xml.OptionsFor(NS_CONFIG) = .{};
        options.namespace_limits.max_comparison_work = 5;
        const parts = [_][]const u8{input};
        _ = try parseParts(NS_CONFIG, std.testing.allocator, options, &parts);
        options.namespace_limits.max_comparison_work = 4;
        try expectProfileFailureSchedules(
            NS_CONFIG,
            options,
            input,
            error.LimitExceeded,
            .namespace_comparison_limit,
            std.mem.indexOf(u8, input, "a:x").?,
            null,
        );
    }
}

test "[failure] - [qualified names]: local parts must begin with NCName characters" {
    inline for (.{ "<a:1 xmlns:a='u'/>", "<a:-x xmlns:a='u'/>", "<a:.x xmlns:a='u'/>" }) |input| {
        try expectProfileFailureSchedules(
            NS_CONFIG,
            .{},
            input,
            error.InvalidXml,
            .malformed_qname,
            3,
            null,
        );
    }
    const pi = "<?a:b bogus?><r/>";
    try expectProfileFailureSchedules(
        NS_CONFIG,
        .{},
        pi,
        error.InvalidXml,
        .malformed_ncname,
        3,
        null,
    );
    const entity = "<r>&a:b;</r>";
    try expectProfileFailureSchedules(
        NS_CONFIG,
        .{},
        entity,
        error.InvalidXml,
        .malformed_ncname,
        5,
        null,
    );
}

test "[unit] - [namespace rollback]: closed scopes release active bytes and reset obeys policy" {
    var reader = try xml.ReaderFor(NS_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<r xmlns:a='outer'><c xmlns:a='inner'/></r>", true);
    var peak_namespace_capacity: usize = 0;
    while (true) switch (try reader.next()) {
        .event => peak_namespace_capacity = @max(
            peak_namespace_capacity,
            reader.memoryUsage().namespace_capacity,
        ),
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expect(peak_namespace_capacity > 0);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().open_name_bytes);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().namespace_binding_count);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().namespace_bytes);
    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().open_name_bytes);
    try std.testing.expect(reader.memoryUsage().namespace_capacity > 0);
    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().namespace_capacity);
}

test "[unit] - [namespace specialization]: raw readers own no namespace state" {
    try std.testing.expect(
        @sizeOf(xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD_FAST)) <
            @sizeOf(xml.ReaderFor(xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD_FAST)),
    );
    var reader = try xml.ReaderFor(xml.Configs.XML10_UTF8_NO_DTD_FAST).init(
        std.testing.allocator,
        .{},
    );
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().namespace_capacity);
    try reader.feed("<r a='v'/>", true);
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().namespace_capacity);
}

test "[unit] - [namespace storage]: warm fixed scope performs no allocator operation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader = try xml.ReaderFor(NS_CONFIG).init(failing.allocator(), .{});
    defer reader.deinit();

    try reader.feed(NAMESPACE_CHURN_INPUT, true);
    try std.testing.expectEqual(@as(usize, 7), (try drainNamespace(&reader)).starts);
    try std.testing.expect(failing.alloc_index > 0);

    try reader.reset(.retain_capacity);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try reader.feed(NAMESPACE_CHURN_INPUT, true);
    try std.testing.expectEqual(@as(usize, 7), (try drainNamespace(&reader)).starts);
    try std.testing.expect(!failing.has_induced_failure);
}

test "[property] - [namespace scope]: deep rebinding churn rolls back under targeted schedules" {
    var storage: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    const depth = 128;
    for (0..depth) |index| try writer.print("<n xmlns:p='urn:{d}'>", .{index});
    for (0..depth) |_| try writer.writeAll("</n>");
    const input = writer.buffered();

    const parts = [_][]const u8{input};
    const expected = try parseParts(NS_CONFIG, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqual(depth, expected.starts);
    try std.testing.expectEqual(depth, expected.ends);
    try std.testing.expectEqual(depth, expected.namespace_declarations);
    try std.testing.expectEqual(
        expected,
        try parseOneByteChunks(NS_CONFIG, std.testing.allocator, .{}, input),
    );
    try std.testing.expectEqual(
        expected,
        try parseFixedChunks(NS_CONFIG, std.testing.allocator, .{}, input, 17),
    );
    try std.testing.expectEqual(
        expected,
        try parseRandomChunks(NS_CONFIG, std.testing.allocator, .{}, input, 0x6e73),
    );

    var reader = try xml.ReaderFor(NS_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(input, true);
    var peak_bindings: usize = 0;
    while (true) switch (try reader.next()) {
        .event => peak_bindings = @max(
            peak_bindings,
            reader.memoryUsage().namespace_binding_count,
        ),
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(depth, peak_bindings);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().namespace_binding_count);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().namespace_bytes);
}

test "[property] - [expanded attributes]: sorted duplicate path preserves source order" {
    var storage: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writer.writeAll("<r xmlns:a='u' xmlns:b='u'");
    for (0..65) |index| try writer.print(" a:x{d}='{d}'", .{ index, index });
    try writer.writeAll("/>");
    const valid = writer.buffered();
    const valid_parts = [_][]const u8{valid};
    const summary = try parseParts(NS_CONFIG, std.testing.allocator, .{}, &valid_parts);
    try std.testing.expectEqual(@as(usize, 65), summary.attributes);
    var limited_options: xml.OptionsFor(NS_CONFIG) = .{};
    limited_options.namespace_limits.max_comparison_work = 1000;
    try expectProfileFailureParts(
        NS_CONFIG,
        limited_options,
        &valid_parts,
        error.LimitExceeded,
        .namespace_comparison_limit,
        valid.len,
        null,
    );

    writer = std.Io.Writer.fixed(&storage);
    try writer.writeAll("<r xmlns:a='u' xmlns:b='u'");
    for (0..65) |index| try writer.print(" a:x{d}='{d}'", .{ index, index });
    try writer.writeAll(" b:x0='duplicate'/>");
    const invalid = writer.buffered();
    const invalid_parts = [_][]const u8{invalid};
    try expectProfileFailureParts(
        NS_CONFIG,
        .{},
        &invalid_parts,
        error.InvalidXml,
        .duplicate_expanded_attribute,
        std.mem.indexOf(u8, invalid, "b:x0").?,
        std.mem.indexOf(u8, invalid, "a:x0").?,
    );
}

const TestExternalResource = struct {
    system_id: []const u8,
    bytes: []const u8,
    source_id: u32,
    encoding_hint: ?xml.SourceEncoding = null,
    transcoder: ?xml.Transcoder = null,
};

const TestResolver = struct {
    resources: []const TestExternalResource,
    active: ?*const TestExternalResource = null,
    cursor: usize = 0,
    resolves: usize = 0,
    reads: usize = 0,
    closes: usize = 0,
    fail_read_after: ?usize = null,
    cancel_read_after: ?usize = null,
    max_read_len: usize = 3,
    parameter_inclusion_source_id: ?u32 = null,
    parameter_inclusion_offset: ?u64 = null,
    reader: ?*xml.Reader = null,
    close_reset_error: ?xml.ResetError = null,

    fn resolver(self: *@This()) xml.Resolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: ?*anyopaque, request: xml.ResolverRequest) xml.ResolverResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.resolves += 1;
        if (request.kind == .parameter_entity) {
            self.parameter_inclusion_source_id = request.inclusion.source_id;
            self.parameter_inclusion_offset = request.inclusion.byte_offset;
        }
        for (self.resources) |*resource| {
            if (!std.mem.eql(u8, resource.system_id, request.system_id)) continue;
            self.active = resource;
            self.cursor = 0;
            return .{ .source = .{
                .context = self,
                .source_id = resource.source_id,
                .base_id = resource.system_id,
                .encoding_hint = resource.encoding_hint,
                .transcoder = resource.transcoder,
                .readFn = read,
                .closeFn = close,
            } };
        }
        return .not_found;
    }

    fn read(context: ?*anyopaque, output: []u8) xml.ResolverReadResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.fail_read_after != null and self.reads == self.fail_read_after.?) return .io_failure;
        if (self.cancel_read_after != null and self.reads == self.cancel_read_after.?) return .cancelled;
        self.reads += 1;
        const resource = self.active.?;
        if (self.cursor == resource.bytes.len) return .end;
        const len = @min(self.max_read_len, @min(output.len, resource.bytes.len - self.cursor));
        @memcpy(output[0..len], resource.bytes[self.cursor..][0..len]);
        self.cursor += len;
        return .{ .bytes = len };
    }

    fn close(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.closes += 1;
        self.active = null;
        if (self.reader) |reader| {
            reader.reset(.{ .slice = "<replacement/>" }, .{}, .retain_capacity) catch |failure| {
                self.close_reset_error = failure;
            };
        }
    }
};

const TestSubsetProvider = struct {
    resources: []const TestExternalResource,
    resolves: usize = 0,

    fn provider(self: *@This()) xml.ExternalSubsetProvider {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: ?*anyopaque, request: xml.ExternalSubsetRequest) xml.ExternalSubsetProviderError!xml.ExternalSubsetResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.resolves += 1;
        for (self.resources) |resource| {
            if (!std.mem.eql(u8, resource.system_id, request.system_id)) continue;
            return .{ .content = .{
                .bytes = resource.bytes,
                .base_id = resource.system_id,
                .source_id = resource.source_id,
            } };
        }
        return .skipped;
    }
};

test "[integration] - [Reader lifecycle]: reset and deinit close active external sources" {
    const document =
        "<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]>" ++
        "<root>&message;</root>";
    const resources = [_]TestExternalResource{
        .{ .system_id = "message.ent", .bytes = "long external text", .source_id = 6 },
    };
    var resolver = TestResolver{ .resources = &resources };
    const options: xml.ReaderOptions = .{
        .external = .resolve,
        .resolver = resolver.resolver(),
    };
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{ .slice = document },
        options,
    );
    var reader_live = true;
    defer if (reader_live) reader.deinit();

    var saw_first_text = false;
    first: while (try reader.next()) |event| switch (event.data) {
        .text => {
            saw_first_text = true;
            break :first;
        },
        else => {},
    };
    try std.testing.expect(saw_first_text);
    try std.testing.expectEqual(@as(usize, 0), resolver.closes);
    try reader.reset(.{ .slice = document }, options, .retain_capacity);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);

    var saw_second_text = false;
    second: while (try reader.next()) |event| switch (event.data) {
        .text => {
            saw_second_text = true;
            break :second;
        },
        else => {},
    };
    try std.testing.expect(saw_second_text);
    resolver.reader = &reader;
    reader.deinit();
    reader_live = false;
    try std.testing.expectEqual(@as(usize, 2), resolver.closes);
    try std.testing.expectEqual(error.InvalidState, resolver.close_reset_error.?);
}

test "[unit] - [Reader reset]: disabling external sources releases inclusion storage" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "broken.ent", .bytes = "<broken", .source_id = 7 },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var reader = try xml.Reader.init(
        std.testing.allocator,
        .{
            .slice = "<!DOCTYPE root [<!ENTITY broken SYSTEM 'broken.ent'>]>" ++
                "<root>&broken;</root>",
        },
        .{ .external = .resolve, .resolver = resolver.resolver() },
    );
    defer reader.deinit();

    while (true) {
        const event = reader.next() catch |failure| {
            try std.testing.expectEqual(error.InvalidXml, failure);
            break;
        };
        if (event == null) return error.ExpectedFailure;
    }
    try std.testing.expectEqual(@as(usize, 1), reader.diagnostic().?.inclusion_trace.len);
    try std.testing.expect(reader.memoryUsage().retained_capacity > 0);

    try reader.reset(
        .{ .slice = "<root/>" },
        .{ .dtd = .reject },
        .retain_capacity,
    );
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
}

test "[integration] - [XML 1.1 external entity]: text declarations and lines are processed" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const external =
        "<?xml version='1.1' encoding='UTF-8'?>A\xc2\x85B\xe2\x80\xa8C\r\xc2\x85D";
    const resources = [_]TestExternalResource{
        .{ .system_id = "text.xml", .bytes = external, .source_id = 81 },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(config) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    const document =
        "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e SYSTEM 'text.xml'>]><r>&e;</r>";
    const parts = [_][]const u8{document};
    const summary = try parseParts(config, std.testing.allocator, options, &parts);
    try std.testing.expectEqualStrings("A\nB\nC\nD", summary.text_bytes[0..summary.text_bytes_len]);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [XML 1.1 external subset]: document rules apply to declarations" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const external =
        "<?xml version='1.1' encoding='UTF-8'?><!ENTITY e '&#x1;'>\xc2\x85";
    const resources = [_]TestExternalResource{
        .{ .system_id = "schema.dtd", .bytes = external, .source_id = 82 },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(config) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    const document =
        "<?xml version='1.1'?><!DOCTYPE r SYSTEM 'schema.dtd'><r>&e;</r>";
    const parts = [_][]const u8{document};
    const summary = try parseParts(config, std.testing.allocator, options, &parts);
    try std.testing.expectEqualSlices(u8, &.{0x1}, summary.text_bytes[0..summary.text_bytes_len]);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [XML 1.1 normalization]: external entities retain source findings" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const external = "e\xcc\x81";
    const resources = [_]TestExternalResource{
        .{ .system_id = "text.xml", .bytes = external, .source_id = 181 },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(config) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    const document =
        "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e SYSTEM 'text.xml'>]><r>&e;</r>";
    const result = try normalizationOutcome(config, options, document, .{ .fixed = 1 });
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, result.status);
    try std.testing.expectEqual(xml.NormalizationIssueKind.not_nfc, result.issue.?.kind);
    try std.testing.expectEqual(@as(u32, 181), result.issue.?.location.source_id);
    try std.testing.expectEqual(@as(u64, 1), result.issue.?.location.byte_offset);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [XML 1.1 normalization]: external UTF-16 is checked incrementally" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const external = try encodeUtf16(std.testing.allocator, "e\xcc\x81", .little, true);
    defer std.testing.allocator.free(external);
    const resources = [_]TestExternalResource{
        .{
            .system_id = "text.xml",
            .bytes = external,
            .source_id = 184,
            .encoding_hint = .utf16_le,
        },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(config) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    const document =
        "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e SYSTEM 'text.xml'>]><r>&e;</r>";
    const result = try normalizationOutcome(config, options, document, .whole);
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, result.status);
    try std.testing.expectEqual(xml.NormalizationIssueKind.not_nfc, result.issue.?.kind);
    try std.testing.expectEqual(@as(u32, 184), result.issue.?.location.source_id);
    try std.testing.expectEqual(@as(u64, 4), result.issue.?.location.byte_offset);
}

test "[integration] - [XML 1.1 normalization]: external DTD and compiled sources are verified" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const declarations = "<!--e\xcc\x81--><!ENTITY e 'ok'>";
    const resources = [_]TestExternalResource{
        .{ .system_id = "schema.dtd", .bytes = declarations, .source_id = 182 },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(config) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    const document =
        "<?xml version='1.1'?><!DOCTYPE r SYSTEM 'schema.dtd'><r>&e;</r>";
    const result = try normalizationOutcome(config, options, document, .whole);
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, result.status);
    try std.testing.expectEqual(xml.NormalizationIssueKind.not_nfc, result.issue.?.kind);
    try std.testing.expectEqual(@as(u32, 182), result.issue.?.location.source_id);
    try std.testing.expectEqual(
        @as(u64, std.mem.indexOf(u8, declarations, "\xcc\x81").?),
        result.issue.?.location.byte_offset,
    );

    const validating_config = xml.Configs.XML11_VALIDATING;
    const reusable_declarations = "<?\xe1\x85\xa1?><!ELEMENT r EMPTY>";
    var subset = try xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "schema.dtd",
        reusable_declarations,
        .{ .version = .xml11, .source_id = 183 },
    );
    defer subset.deinit();
    var validating_options: xml.OptionsFor(validating_config) = .{};
    validating_options.validation.external_subset = &subset;
    const reused = try normalizationOutcome(
        validating_config,
        validating_options,
        "<?xml version='1.1'?><!DOCTYPE r SYSTEM 'schema.dtd'><r/>",
        .whole,
    );
    try std.testing.expectEqual(xml.ProfileNormalizationStatus.not_normalized, reused.status);
    try std.testing.expectEqual(
        xml.NormalizationIssueKind.composing_start,
        reused.issue.?.kind,
    );
    try std.testing.expectEqual(@as(u32, 183), reused.issue.?.location.source_id);
    try std.testing.expectEqual(@as(u64, 2), reused.issue.?.location.byte_offset);
}

test "[failure] - [XML 1.1 external sources]: restricted literals and malformed declarations fail" {
    const config = xml.Configs.XML11_NONVALIDATING;
    const cases = .{
        .{
            "schema.dtd",
            "<!ELEMENT r (#PCDATA)><!ENTITY e 'bad\x7ftext'>",
            "<?xml version='1.1'?><!DOCTYPE r SYSTEM 'schema.dtd'><r>&e;</r>",
            xml.DiagnosticCode.forbidden_character,
        },
        .{
            "text.xml",
            "<?xml version='1.0' \xc2\x85 encoding='UTF-8'?>",
            "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e SYSTEM 'text.xml'>]><r>&e;</r>",
            xml.DiagnosticCode.malformed_declaration,
        },
        .{
            "text.xml",
            "<?xml encoding='UTF-8' version='1.1'?>",
            "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e SYSTEM 'text.xml'>]><r>&e;</r>",
            xml.DiagnosticCode.malformed_declaration,
        },
        .{
            "text.xml",
            "<?xml version='1.1' encoding='UTF-8' extra='value'?>",
            "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e SYSTEM 'text.xml'>]><r>&e;</r>",
            xml.DiagnosticCode.malformed_declaration,
        },
    };
    inline for (cases, 0..) |case, index| {
        const resources = [_]TestExternalResource{
            .{ .system_id = case[0], .bytes = case[1], .source_id = 90 + index },
        };
        var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
        var options: xml.OptionsFor(config) = .{};
        options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
        var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
        defer reader.deinit();
        try reader.feed(case[2], true);
        while (true) {
            _ = reader.next() catch |err| {
                try std.testing.expect(err == error.InvalidDtd or err == error.InvalidXml);
                try std.testing.expectEqual(case[3], reader.diagnostic().?.code);
                break;
            };
        }
        try std.testing.expectEqual(@as(usize, 1), resolver.closes);
    }
}

test "[integration] - [compiled external subset]: fresh and reused validation agree" {
    const config = xml.Configs.XML10_VALIDATING;
    const declarations = "<!ELEMENT root (item+)><!ELEMENT item (#PCDATA)>" ++
        "<!ATTLIST item id ID #REQUIRED>";
    const document = "<!DOCTYPE root SYSTEM 'schema.dtd'><root><item id='one'>text</item></root>";
    var subset = try xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "schema.dtd",
        declarations,
        .{ .source_id = 71 },
    );
    defer subset.deinit();

    const resources = [_]TestExternalResource{
        .{ .system_id = "schema.dtd", .bytes = declarations, .source_id = 71 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var fresh_options: xml.OptionsFor(config) = .{};
    fresh_options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var fresh = try xml.ReaderFor(config).init(std.testing.allocator, fresh_options);
    defer fresh.deinit();
    try fresh.feed(document, true);
    var fresh_status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try fresh.next()) {
        .event => |event| switch (event) {
            .document_end => |end| fresh_status = end.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };

    var reused_options: xml.OptionsFor(config) = .{};
    reused_options.validation.external_subset = &subset;
    var reused = try xml.ReaderFor(config).init(std.testing.allocator, reused_options);
    defer reused.deinit();
    try reused.feed(document, true);
    var reused_status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reused.next()) {
        .event => |event| switch (event) {
            .document_end => |end| reused_status = end.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };

    try std.testing.expectEqual(xml.ProfileValidationStatus.valid, fresh_status.?);
    try std.testing.expectEqual(fresh_status.?, reused_status.?);
    try std.testing.expectEqual(@as(usize, 1), resolver.resolves);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
    try std.testing.expect(subset.memoryUsage().declaration_capacity > 0);
    try std.testing.expect(subset.memoryUsage().validation_capacity > 0);
}

test "[integration] - [XML 1.1 compiled subset]: edition must match the document" {
    var subset = try xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "schema.dtd",
        "<!ELEMENT root (#PCDATA)><!ENTITY e '&#x1;'>",
        .{ .version = .xml11, .source_id = 83 },
    );
    defer subset.deinit();

    const xml11_config = xml.Configs.XML11_VALIDATING;
    var xml11_options: xml.OptionsFor(xml11_config) = .{};
    xml11_options.validation.external_subset = &subset;
    const xml11_input =
        "<?xml version='1.1'?><!DOCTYPE root SYSTEM 'schema.dtd'><root>&e;</root>";
    const xml11_parts = [_][]const u8{xml11_input};
    const summary = try parseParts(
        xml11_config,
        std.testing.allocator,
        xml11_options,
        &xml11_parts,
    );
    try std.testing.expectEqualSlices(u8, &.{0x1}, summary.text_bytes[0..summary.text_bytes_len]);

    const xml10_config = xml.Configs.XML10_VALIDATING;
    var xml10_options: xml.OptionsFor(xml10_config) = .{};
    xml10_options.validation.external_subset = &subset;
    const xml10_input = "<!DOCTYPE root SYSTEM 'schema.dtd'><root/>";
    const xml10_parts = [_][]const u8{xml10_input};
    try expectProfileFailureParts(
        xml10_config,
        xml10_options,
        &xml10_parts,
        error.InvalidDtd,
        .external_subset_mismatch,
        std.mem.indexOf(u8, xml10_input, " root").?,
        null,
    );
}

test "[integration] - [compiled external subset]: fresh and reused diagnostics agree" {
    const config = xml.Configs.XML10_VALIDATING;
    const declarations = "<!ELEMENT item EMPTY>\n<!ELEMENT root (item|item)>";
    const document = "<!DOCTYPE root SYSTEM 'schema.dtd'><root><item/></root>";
    var subset = try xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "schema.dtd",
        declarations,
        .{ .source_id = 73 },
    );
    defer subset.deinit();

    const resources = [_]TestExternalResource{
        .{ .system_id = "schema.dtd", .bytes = declarations, .source_id = 73 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var fresh_options: xml.OptionsFor(config) = .{};
    fresh_options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    fresh_options.validation.collect_validity_errors = true;
    var fresh = try xml.ReaderFor(config).init(std.testing.allocator, fresh_options);
    defer fresh.deinit();
    try fresh.feed(document, true);
    var fresh_status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try fresh.next()) {
        .event => |event| switch (event) {
            .document_end => |document_end| fresh_status = document_end.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };

    var reused_options: xml.OptionsFor(config) = .{};
    reused_options.validation.collect_validity_errors = true;
    reused_options.validation.external_subset = &subset;
    var reused = try xml.ReaderFor(config).init(std.testing.allocator, reused_options);
    defer reused.deinit();
    try reused.feed(document, true);
    var reused_status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reused.next()) {
        .event => |event| switch (event) {
            .document_end => |document_end| reused_status = document_end.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };

    try std.testing.expectEqual(xml.ProfileValidationStatus.invalid, fresh_status.?);
    try std.testing.expectEqual(fresh_status.?, reused_status.?);
    const fresh_diagnostic = fresh.diagnostic().?;
    const reused_diagnostic = reused.diagnostic().?;
    try std.testing.expectEqual(fresh_diagnostic.code, reused_diagnostic.code);
    try std.testing.expectEqualDeep(fresh_diagnostic.primary, reused_diagnostic.primary);
    try std.testing.expectEqualDeep(fresh_diagnostic.related, reused_diagnostic.related);
    try std.testing.expectEqualDeep(fresh_diagnostic.inclusion_trace, reused_diagnostic.inclusion_trace);
    try std.testing.expectEqual(@as(u32, 73), reused_diagnostic.primary.source_id);
    try std.testing.expectEqual(@as(usize, 1), reused_diagnostic.inclusion_trace.len);
    try std.testing.expectEqual(@as(u32, 0), reused_diagnostic.inclusion_trace[0].source_id);
    const second_line = subset.sourcePosition(73, "<!ELEMENT item EMPTY>\n".len).?;
    try std.testing.expectEqual(@as(u64, 2), second_line.line);
    try std.testing.expectEqual(@as(u64, 1), second_line.byte_column);
}

test "[integration] - [compiled external subset]: nested diagnostic ancestry is reusable" {
    const config = xml.Configs.XML10_VALIDATING;
    const declarations = "<!ENTITY % child SYSTEM 'child.dtd'>%child;";
    const child = "<!ELEMENT item EMPTY>\n<!ELEMENT root (item|item)>";
    const document = "<!DOCTYPE root SYSTEM 'schema.dtd'><root><item/></root>";
    const resources = [_]TestExternalResource{
        .{ .system_id = "schema.dtd", .bytes = declarations, .source_id = 80 },
        .{ .system_id = "child.dtd", .bytes = child, .source_id = 81 },
    };
    var provider = TestSubsetProvider{ .resources = &resources };
    var subset = try xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "schema.dtd",
        declarations,
        .{ .source_id = 80, .provider = provider.provider() },
    );
    defer subset.deinit();
    try std.testing.expectEqual(@as(usize, 1), provider.resolves);
    const inclusion = subset.sourceInclusion(81).?;
    try std.testing.expectEqual(@as(u32, 80), inclusion.source_id);
    try std.testing.expectEqual(
        std.mem.indexOf(u8, declarations, "%child;").?,
        inclusion.offset,
    );

    var resolver = TestResolver{ .resources = &resources };
    var fresh_options: xml.OptionsFor(config) = .{};
    fresh_options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    fresh_options.validation.collect_validity_errors = true;
    var fresh = try xml.ReaderFor(config).init(std.testing.allocator, fresh_options);
    defer fresh.deinit();
    try fresh.feed(document, true);
    while (true) switch (try fresh.next()) {
        .event => {},
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };

    var reused_options: xml.OptionsFor(config) = .{};
    reused_options.validation.collect_validity_errors = true;
    reused_options.validation.external_subset = &subset;
    var reused = try xml.ReaderFor(config).init(std.testing.allocator, reused_options);
    defer reused.deinit();
    try reused.feed(document, true);
    while (true) switch (try reused.next()) {
        .event => {},
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };

    const fresh_diagnostic = fresh.diagnostic().?;
    const reused_diagnostic = reused.diagnostic().?;
    try std.testing.expectEqual(fresh_diagnostic.code, reused_diagnostic.code);
    try std.testing.expectEqualDeep(fresh_diagnostic.primary, reused_diagnostic.primary);
    try std.testing.expectEqualDeep(fresh_diagnostic.related, reused_diagnostic.related);
    try std.testing.expectEqualDeep(fresh_diagnostic.inclusion_trace, reused_diagnostic.inclusion_trace);
    try std.testing.expectEqual(@as(u32, 81), reused_diagnostic.primary.source_id);
    try std.testing.expectEqual(@as(usize, 2), reused_diagnostic.inclusion_trace.len);
    try std.testing.expectEqual(@as(u32, 80), reused_diagnostic.inclusion_trace[0].source_id);
    try std.testing.expectEqual(@as(u32, 0), reused_diagnostic.inclusion_trace[1].source_id);
}

fn externalSubsetAllocationAttempt(allocator: std.mem.Allocator) !void {
    const declarations = "<!ENTITY % child SYSTEM 'child.dtd'>%child;";
    const resources = [_]TestExternalResource{
        .{ .system_id = "child.dtd", .bytes = "<!ELEMENT root EMPTY>", .source_id = 91 },
    };
    var provider = TestSubsetProvider{ .resources = &resources };
    var subset = try xml.ExternalSubset.compileDecoded(
        allocator,
        "schema.dtd",
        declarations,
        .{ .source_id = 90, .provider = provider.provider() },
    );
    defer subset.deinit();
}

test "[failure] - [compiled external subset]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        externalSubsetAllocationAttempt,
        .{},
    );
}

test "[failure] - [compiled external subset]: rejects a skipped parameter entity" {
    var provider = TestSubsetProvider{ .resources = &.{} };
    const result = xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "schema.dtd",
        "<!ELEMENT root EMPTY><!ENTITY % child SYSTEM 'child.dtd'>%child;",
        .{ .provider = provider.provider() },
    );
    if (result) |value| {
        var subset = value;
        subset.deinit();
        return error.ExpectedFailure;
    } else |err| {
        try std.testing.expectEqual(error.UnsupportedFeature, err);
    }
    try std.testing.expectEqual(@as(usize, 1), provider.resolves);
}

test "[failure] - [non-validating standalone]: externally declared entity is undeclared" {
    const resources = [_]TestExternalResource{
        .{
            .system_id = "schema.dtd",
            .bytes = "<!ELEMENT root (#PCDATA)><!ENTITY message 'external'>",
            .source_id = 72,
        },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed(
        "<?xml version='1.0' standalone='yes'?><!DOCTYPE root SYSTEM 'schema.dtd'><root>&message;</root>",
        true,
    );
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            break;
        };
    }
    try std.testing.expectEqual(xml.DiagnosticCode.undeclared_entity, reader.diagnostic().?.code);
}

test "[integration] - [compiled external subset]: internal declarations retain precedence" {
    const config = xml.Configs.XML10_VALIDATING;
    var subset = try xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "schema.dtd",
        "<!ELEMENT root EMPTY><!ATTLIST root mode (a|b) 'a'>",
        .{},
    );
    defer subset.deinit();
    var options: xml.OptionsFor(config) = .{};
    options.validation.external_subset = &subset;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root SYSTEM 'schema.dtd' [<!ATTLIST root mode (a|b) 'b'>]><root/>",
        true,
    );
    var default_value: ?u8 = null;
    var status: ?xml.ProfileValidationStatus = null;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| {
                try std.testing.expectEqual(@as(usize, 1), start.attributes[0].value.len);
                default_value = start.attributes[0].value[0];
            },
            .document_end => |end| status = end.validation,
            else => {},
        },
        .done => break,
        .need_input => return error.UnexpectedNeedInput,
    };
    try std.testing.expectEqual(@as(u8, 'b'), default_value.?);
    try std.testing.expectEqual(xml.ProfileValidationStatus.valid, status.?);
}

test "[integration] - [compiled external subset]: content position limits remain per model" {
    const config = xml.Configs.XML10_VALIDATING;
    const cases = [_]struct {
        declarations: []const u8,
        document: []const u8,
    }{
        .{
            .declarations = "<!ELEMENT root (#PCDATA|a|b)*>" ++
                "<!ELEMENT a (#PCDATA|c|d)*>" ++
                "<!ELEMENT b EMPTY><!ELEMENT c EMPTY><!ELEMENT d EMPTY>",
            .document = "<!DOCTYPE root SYSTEM 'schema.dtd'><root><a><c/></a><b/></root>",
        },
        .{
            .declarations = "<!ELEMENT root (a,b)><!ELEMENT a EMPTY><!ELEMENT b EMPTY>",
            .document = "<!DOCTYPE root SYSTEM 'schema.dtd'><root><a/><b/></root>",
        },
    };

    for (cases) |case| {
        var subset = try xml.ExternalSubset.compileDecoded(
            std.testing.allocator,
            "schema.dtd",
            case.declarations,
            .{},
        );
        defer subset.deinit();

        var options: xml.OptionsFor(config) = .{};
        options.validation.limits.max_content_positions = 2;
        options.validation.external_subset = &subset;
        var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
        defer reader.deinit();
        try reader.feed(case.document, true);
        var status: ?xml.ProfileValidationStatus = null;
        while (true) switch (try reader.next()) {
            .event => |event| switch (event) {
                .document_end => |end| status = end.validation,
                else => {},
            },
            .done => break,
            .need_input => return error.UnexpectedNeedInput,
        };
        try std.testing.expectEqual(xml.ProfileValidationStatus.valid, status.?);

        options.validation.limits.max_content_positions = 1;
        var strict_reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
        defer strict_reader.deinit();
        try strict_reader.feed(case.document, true);
        while (true) {
            const result = strict_reader.next() catch |err| {
                try std.testing.expectEqual(error.LimitExceeded, err);
                try std.testing.expectEqual(
                    xml.DiagnosticCode.validation_content_position_limit,
                    strict_reader.diagnostic().?.code,
                );
                break;
            };
            switch (result) {
                .event => {},
                .done => return error.ExpectedLimitFailure,
                .need_input => return error.UnexpectedNeedInput,
            }
        }
    }
}

test "[failure] - [compiled external subset]: identifier mismatch is explicit" {
    const config = xml.Configs.XML10_VALIDATING;
    var subset = try xml.ExternalSubset.compileDecoded(
        std.testing.allocator,
        "expected.dtd",
        "<!ELEMENT root EMPTY>",
        .{},
    );
    defer subset.deinit();
    var options: xml.OptionsFor(config) = .{};
    options.validation.external_subset = &subset;
    var reader = try xml.ReaderFor(config).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'other.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidDtd, err);
            break;
        };
    }
    try std.testing.expectEqual(
        xml.DiagnosticCode.external_subset_mismatch,
        reader.diagnostic().?.code,
    );
}

fn testIdentityTranscoder(
    _: ?*anyopaque,
    input: []const u8,
    _: bool,
    output: []u8,
    source_advances: []u8,
) xml.TranscodeStep {
    if (input.len == 0) return .need_input;
    if (output.len == 0) return .need_output;
    const len = @min(input.len, output.len);
    @memcpy(output[0..len], input[0..len]);
    @memset(source_advances[0..len], 1);
    return .{ .progress = .{ .consumed = len, .produced = len } };
}

test "[integration] - [internal DTD profile]: has no resolver option or external acquisition path" {
    try std.testing.expect(!@hasField(xml.OptionsFor(INTERNAL_DTD_CONFIG), "resolver"));
    var reader = try xml.ReaderFor(INTERNAL_DTD_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root [<!ENTITY local 'ok'>]><root>&local;</root>", true);
    var text_bytes: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |text| text_bytes += text.bytes.len,
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 2), text_bytes);
}

test "[integration] - [external policy]: skipped general entity reports identifiers and reference" {
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    const input = "<!DOCTYPE root [<!ENTITY message PUBLIC 'public' 'message.ent'>]><root>&message;</root>";
    try reader.feed(input, true);
    var observed = false;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .skipped_entity => |skipped| {
                observed = true;
                try std.testing.expectEqual(xml.ProfileSkippedEntityKind.general_entity, skipped.kind);
                try std.testing.expectEqualStrings("message", skipped.name.?);
                try std.testing.expectEqualStrings("public", skipped.public_id.?);
                try std.testing.expectEqualStrings("message.ent", skipped.system_id.?);
                try std.testing.expectEqual(
                    @as(u64, std.mem.indexOf(u8, input, "&message;").?),
                    skipped.reference.byte_offset,
                );
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expect(observed);
}

test "[integration] - [external policy]: skipped subset and parameter entity are explicit" {
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root SYSTEM 'external.dtd' [<!ENTITY % declarations SYSTEM 'declarations.ent'>%declarations;]><root/>",
        true,
    );
    var subset_events: usize = 0;
    var parameter_events: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .skipped_entity => |skipped| switch (skipped.kind) {
                .external_subset => {
                    subset_events += 1;
                    try std.testing.expectEqualStrings("external.dtd", skipped.system_id.?);
                },
                .parameter_entity => {
                    parameter_events += 1;
                    try std.testing.expectEqualStrings("declarations", skipped.name.?);
                    try std.testing.expectEqualStrings("declarations.ent", skipped.system_id.?);
                },
                .general_entity => return error.UnexpectedGeneralEntity,
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 1), subset_events);
    try std.testing.expectEqual(@as(usize, 1), parameter_events);
}

test "[integration] - [external entities]: resolves subset, parameter, and general sources" {
    const resources = [_]TestExternalResource{
        .{
            .system_id = "external.dtd",
            .bytes = "<!ENTITY % declarations SYSTEM 'declarations.ent'>%declarations;" ++
                "<!ENTITY message SYSTEM 'message.ent'>" ++
                "<![IGNORE[<!ELEMENT ignored EMPTY>]]>" ++
                "<![INCLUDE[<!ATTLIST root source CDATA 'external'>]]>",
            .source_id = 10,
        },
        .{
            .system_id = "declarations.ent",
            .bytes = "<?xml encoding='UTF-8'?><!ELEMENT root (#PCDATA)>",
            .source_id = 11,
        },
        .{
            .system_id = "message.ent",
            .bytes = "<?xml encoding='UTF-8'?>hello",
            .source_id = 12,
        },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root>&message;</root>", true);
    var text: [16]u8 = undefined;
    var text_len: usize = 0;
    var attributes: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .start_element => |start| attributes += start.attributes.len,
            .text => |fragment| {
                @memcpy(text[text_len..][0..fragment.bytes.len], fragment.bytes);
                text_len += fragment.bytes.len;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqualStrings("hello", text[0..text_len]);
    try std.testing.expectEqual(@as(usize, 1), attributes);
    try std.testing.expectEqual(@as(usize, 3), resolver.resolves);
    try std.testing.expectEqual(@as(usize, 3), resolver.closes);
    try std.testing.expectEqual(@as(?u32, 10), resolver.parameter_inclusion_source_id);
    try std.testing.expectEqual(
        @as(?u64, std.mem.indexOf(u8, resources[0].bytes, "%declarations;").?),
        resolver.parameter_inclusion_offset,
    );
}

test "[integration] - [external encoding]: decodes UTF-16 general entity and tracks source" {
    const utf16 = "\xff\xfe<\x00?\x00x\x00m\x00l\x00 \x00e\x00n\x00c\x00o\x00d\x00i\x00n\x00g\x00=\x00'\x00U\x00T\x00F\x00-\x001\x006\x00'\x00?\x00>\x00h\x00i\x00";
    const resources = [_]TestExternalResource{
        .{ .system_id = "message.ent", .bytes = utf16, .source_id = 27 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>", true);
    var external_text: [8]u8 = undefined;
    var external_text_len: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |text| {
                @memcpy(external_text[external_text_len..][0..text.bytes.len], text.bytes);
                external_text_len += text.bytes.len;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqualStrings("hi", external_text[0..external_text_len]);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external encoding]: caller transcoder keeps short source input" {
    const logical = "hi";
    var encoded: [logical.len * 2]u8 = undefined;
    pairEncode(&encoded, logical);
    const resources = [_]TestExternalResource{
        .{
            .system_id = "message.ent",
            .bytes = &encoded,
            .source_id = 28,
            .transcoder = pairTranscoder(),
        },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>",
        true,
    );

    var text: [logical.len]u8 = undefined;
    var text_len: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => |value| {
                @memcpy(text[text_len..][0..value.bytes.len], value.bytes);
                text_len += value.bytes.len;
            },
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqualStrings(logical, text[0..text_len]);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external encoding]: buffered source receives its final window" {
    const resources = [_]TestExternalResource{
        .{
            .system_id = "external.dtd",
            .bytes = "<!ELEMENT root EMPTY>",
            .source_id = 29,
            .transcoder = .{ .context = null, .runFn = finalIdentityTranscode },
        },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external encoding]: explicit transcoder owns byte zero and final input" {
    const cases = [_]struct {
        bytes: []const u8,
        transcoder: xml.Transcoder,
    }{
        .{
            .bytes = "",
            .transcoder = .{ .context = null, .runFn = finalIdentityTranscode },
        },
        .{
            .bytes = "\xef\xbb\xbf<!ELEMENT root EMPTY>",
            .transcoder = .{ .context = null, .runFn = prefixedIdentityTranscode },
        },
    };
    for (cases, 31..) |case, source_id| {
        const resources = [_]TestExternalResource{.{
            .system_id = "external.dtd",
            .bytes = case.bytes,
            .source_id = @intCast(source_id),
            .transcoder = case.transcoder,
        }};
        var resolver = TestResolver{ .resources = &resources };
        var options: xml.OptionsFor(DTD_CONFIG) = .{};
        options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
        var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
        defer reader.deinit();
        try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
        while (true) switch (try reader.next()) {
            .event => {},
            .need_input => return error.UnexpectedNeedInput,
            .done => break,
        };
        try std.testing.expectEqual(@as(usize, 1), resolver.closes);
    }
}

test "[integration] - [external encoding]: transcoder cancellation keeps its source and closes once" {
    var counter: TranscodeCallCounter = .{};
    const resources = [_]TestExternalResource{
        .{
            .system_id = "external.dtd",
            .bytes = "x",
            .source_id = 30,
            .transcoder = .{ .context = &counter, .runFn = cancellingTranscode },
        },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);

    while (true) {
        const step = reader.next() catch |failure| {
            try std.testing.expectEqual(error.Cancelled, failure);
            break;
        };
        if (step == .done) return error.ExpectedCancellation;
    }
    const diagnostic = reader.diagnostic().?;
    try std.testing.expectEqual(xml.DiagnosticCode.transcoder_cancelled, diagnostic.code);
    try std.testing.expectEqual(@as(u32, 30), diagnostic.primary.source_id);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.primary.byte_offset);
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
    try std.testing.expectError(error.Cancelled, reader.next());
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external cleanup]: read failure closes once and stays distinct" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "external.dtd", .bytes = "<!ELEMENT root EMPTY>", .source_id = 4 },
    };
    var resolver = TestResolver{ .resources = &resources, .fail_read_after = 1 };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.ReadFailed, err);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
    try std.testing.expectError(error.ReadFailed, reader.next());
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external diagnostics]: malformed subset identifies its source" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "external.dtd", .bytes = "<!ELEMENT root", .source_id = 42 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidDtd, err);
            try std.testing.expectEqual(@as(u32, 42), reader.diagnostic().?.primary.source_id);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external diagnostics]: malformed source encoding identifies its source byte" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "external.dtd", .bytes = "\xff\xfe<", .source_id = 46 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidDtd, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(xml.DiagnosticCode.malformed_encoding, diagnostic.code);
            try std.testing.expectEqual(@as(u32, 46), diagnostic.primary.source_id);
            try std.testing.expectEqual(@as(u64, 2), diagnostic.primary.byte_offset);
            try std.testing.expectEqual(@as(u64, 1), diagnostic.primary.line);
            try std.testing.expectEqual(@as(u64, 1), diagnostic.primary.byte_column);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external diagnostics]: unavailable caller encoding remains distinct" {
    const resources = [_]TestExternalResource{
        .{
            .system_id = "external.dtd",
            .bytes = "<!ELEMENT root EMPTY>",
            .source_id = 47,
            .encoding_hint = .other,
        },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.UnsupportedFeature, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(xml.DiagnosticCode.unsupported_encoding, diagnostic.code);
            try std.testing.expectEqual(@as(u32, 47), diagnostic.primary.source_id);
            try std.testing.expectEqual(@as(u64, 0), diagnostic.primary.byte_offset);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external diagnostics]: text declaration encoding conflict identifies its token" {
    const external = "<?xml encoding='UTF-16'?><!ELEMENT root EMPTY>";
    const resources = [_]TestExternalResource{
        .{ .system_id = "external.dtd", .bytes = external, .source_id = 48 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidDtd, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(xml.DiagnosticCode.encoding_mismatch, diagnostic.code);
            try std.testing.expectEqual(@as(u32, 48), diagnostic.primary.source_id);
            try std.testing.expectEqual(
                @as(u64, std.mem.indexOf(u8, external, "UTF-16").?),
                diagnostic.primary.byte_offset,
            );
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external diagnostics]: UTF-16 DTD offsets remain original after declaration and CRLF normalization" {
    const ascii = "<?xml encoding='UTF-16'?>\r\n<!ELEMENT root EMPTY>\r\n?";
    var utf16: [2 + ascii.len * 2]u8 = undefined;
    utf16[0] = 0xff;
    utf16[1] = 0xfe;
    for (ascii, 0..) |byte, index| {
        utf16[2 + index * 2] = byte;
        utf16[2 + index * 2 + 1] = 0;
    }
    const resources = [_]TestExternalResource{
        .{ .system_id = "external.dtd", .bytes = &utf16, .source_id = 43 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidDtd, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(@as(u32, 43), diagnostic.primary.source_id);
            const invalid_offset = 2 + std.mem.lastIndexOfScalar(u8, ascii, '?').? * 2;
            try std.testing.expectEqual(@as(u64, invalid_offset), diagnostic.primary.byte_offset);
            try std.testing.expectEqual(@as(u64, 3), diagnostic.primary.line);
            try std.testing.expectEqual(@as(u64, 1), diagnostic.primary.byte_column);
            break;
        };
    }
}

test "[integration] - [external diagnostics]: caller transcoder supplies exact per-output DTD offsets" {
    const external = "<!ELEMENT root EMPTY>?";
    const transcoder: xml.Transcoder = .{ .context = null, .runFn = testIdentityTranscoder };
    const resources = [_]TestExternalResource{
        .{
            .system_id = "external.dtd",
            .bytes = external,
            .source_id = 44,
            .transcoder = transcoder,
        },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = external.len };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidDtd, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(@as(u32, 44), diagnostic.primary.source_id);
            try std.testing.expectEqual(
                @as(u64, std.mem.indexOfScalar(u8, external, '?').?),
                diagnostic.primary.byte_offset,
            );
            break;
        };
    }
}

test "[integration] - [external diagnostics]: caller-transcoded general entity keeps source offsets" {
    const transcoder: xml.Transcoder = .{ .context = null, .runFn = testIdentityTranscoder };
    const resources = [_]TestExternalResource{
        .{
            .system_id = "message.ent",
            .bytes = "ab<",
            .source_id = 45,
            .transcoder = transcoder,
        },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed(
        "<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>",
        true,
    );
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(@as(u32, 45), diagnostic.primary.source_id);
            try std.testing.expectEqual(@as(u64, 2), diagnostic.primary.byte_offset);
            try std.testing.expectEqual(@as(usize, 1), diagnostic.inclusion_trace.len);
            try std.testing.expectEqual(@as(u32, 0), diagnostic.inclusion_trace[0].source_id);
            break;
        };
    }
}

test "[integration] - [external diagnostics]: nested DTD failures retain the immediate-to-root inclusion chain" {
    const resources = [_]TestExternalResource{
        .{
            .system_id = "external.dtd",
            .bytes = "\n<!ENTITY % nested SYSTEM 'nested.ent'>\n%nested;",
            .source_id = 101,
        },
        .{ .system_id = "nested.ent", .bytes = "<!ELEMENT root", .source_id = 102 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidDtd, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(@as(u32, 102), diagnostic.primary.source_id);
            try std.testing.expectEqual(@as(usize, 2), diagnostic.inclusion_trace.len);
            try std.testing.expectEqual(@as(u32, 101), diagnostic.inclusion_trace[0].source_id);
            try std.testing.expectEqual(@as(u64, 3), diagnostic.inclusion_trace[0].line);
            try std.testing.expectEqual(@as(u64, 1), diagnostic.inclusion_trace[0].byte_column);
            try std.testing.expectEqual(@as(u32, 0), diagnostic.inclusion_trace[1].source_id);
            break;
        };
    }
}

test "[integration] - [external diagnostics]: nested resolver failure points to the requesting source" {
    const external = "<!ENTITY % nested SYSTEM 'missing.ent'>%nested;";
    const resources = [_]TestExternalResource{
        .{ .system_id = "external.dtd", .bytes = external, .source_id = 103 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.ResolverFailed, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(xml.DiagnosticCode.resolver_not_found, diagnostic.code);
            try std.testing.expectEqual(@as(u32, 103), diagnostic.primary.source_id);
            try std.testing.expectEqual(
                @as(u64, std.mem.indexOf(u8, external, "%nested;").?),
                diagnostic.primary.byte_offset,
            );
            try std.testing.expectEqual(@as(usize, 1), diagnostic.inclusion_trace.len);
            try std.testing.expectEqual(@as(u32, 0), diagnostic.inclusion_trace[0].source_id);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external diagnostics]: nested general-entity failure retains both inclusions" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "outer.ent", .bytes = "&inner;", .source_id = 104 },
        .{ .system_id = "inner.ent", .bytes = "<", .source_id = 105 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    const document = "<!DOCTYPE root [" ++
        "<!ENTITY outer SYSTEM 'outer.ent'>" ++
        "<!ENTITY inner SYSTEM 'inner.ent'>" ++
        "]><root>&outer;</root>";
    try reader.feed(document, true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.InvalidXml, err);
            const diagnostic = reader.diagnostic().?;
            try std.testing.expectEqual(@as(u32, 105), diagnostic.primary.source_id);
            try std.testing.expectEqual(@as(usize, 2), diagnostic.inclusion_trace.len);
            try std.testing.expectEqual(@as(u32, 104), diagnostic.inclusion_trace[0].source_id);
            try std.testing.expectEqual(@as(u32, 0), diagnostic.inclusion_trace[1].source_id);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 2), resolver.closes);
}

test "[integration] - [external limits]: streamed expansion stops at the semantic byte boundary" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "message.ent", .bytes = "hello", .source_id = 5 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.dtd_limits.max_expanded_bytes = 4;
    options.dtd_limits.expansion_ratio_minimum_bytes = 1024;
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.LimitExceeded, err);
            try std.testing.expectEqual(xml.DiagnosticCode.entity_expansion_limit, reader.diagnostic().?.code);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external limits]: acquisition count and source bytes fail before excess use" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "message.ent", .bytes = "hello", .source_id = 8 },
        .{ .system_id = "external.dtd", .bytes = "<!ENTITY message SYSTEM 'message.ent'>", .source_id = 9 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{
        .policy = .resolve,
        .resolver = resolver.resolver(),
        .max_source_bytes = 4,
    };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    const input = "<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>";
    try reader.feed(input, true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.LimitExceeded, err);
            try std.testing.expectEqual(xml.DiagnosticCode.external_resource_bytes_limit, reader.diagnostic().?.code);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);

    try reader.reset(.retain_capacity);
    resolver.reads = 0;
    resolver.resolves = 0;
    resolver.closes = 0;
    options.resolver.max_source_bytes = 64;
    options.resolver.max_resources = 1;
    reader.options = options;
    try reader.feed(
        "<!DOCTYPE root SYSTEM 'external.dtd'><root>&message;</root>",
        true,
    );
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.LimitExceeded, err);
            try std.testing.expectEqual(xml.DiagnosticCode.external_resource_count_limit, reader.diagnostic().?.code);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.resolves);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external cleanup]: cancellation and reset close active sources once" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "message.ent", .bytes = "long external text", .source_id = 6 },
    };
    var resolver = TestResolver{ .resources = &resources, .cancel_read_after = 0 };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.Cancelled, err);
            try std.testing.expectEqual(xml.DiagnosticCode.resolver_cancelled, reader.diagnostic().?.code);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);

    try reader.reset(.retain_capacity);
    resolver.cancel_read_after = null;
    resolver.reads = 0;
    try reader.feed("<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>", true);
    parse: while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => break :parse,
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => return error.UnexpectedDone,
    };
    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 2), resolver.closes);
}

test "[integration] - [external cleanup]: deinit closes an active source once" {
    const resources = [_]TestExternalResource{
        .{ .system_id = "message.ent", .bytes = "long external text", .source_id = 7 },
    };
    var resolver = TestResolver{ .resources = &resources };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    try reader.feed("<!DOCTYPE root [<!ENTITY message SYSTEM 'message.ent'>]><root>&message;</root>", true);
    parse: while (true) switch (try reader.next()) {
        .event => |event| switch (event) {
            .text => break :parse,
            else => {},
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => return error.UnexpectedDone,
    };
    reader.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

test "[integration] - [external memory]: large generated entity keeps reader storage flat" {
    const GeneratedResolver = struct {
        remaining: usize,
        closes: usize = 0,

        fn resolver(self: *@This()) xml.Resolver {
            return .{ .context = self, .resolveFn = resolve };
        }

        fn resolve(context: ?*anyopaque, _: xml.ResolverRequest) xml.ResolverResult {
            return .{ .source = .{
                .context = context,
                .source_id = 31,
                .encoding_hint = .utf8,
                .readFn = read,
                .closeFn = close,
            } };
        }

        fn read(context: ?*anyopaque, output: []u8) xml.ResolverReadResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.remaining == 0) return .end;
            const len = @min(output.len, self.remaining);
            @memset(output[0..len], 'x');
            self.remaining -= len;
            return .{ .bytes = len };
        }

        fn close(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closes += 1;
        }
    };
    const generated_bytes = 2 * 1024 * 1024;
    var resolver = GeneratedResolver{ .remaining = generated_bytes };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.dtd_limits.max_expanded_bytes = generated_bytes;
    options.dtd_limits.max_expansion_ratio = generated_bytes;
    options.dtd_limits.expansion_ratio_minimum_bytes = generated_bytes;
    options.resolver = .{
        .policy = .resolve,
        .resolver = resolver.resolver(),
        .max_source_bytes = generated_bytes,
        .max_total_bytes = generated_bytes,
    };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root [<!ENTITY data SYSTEM 'generated.ent'>]><root>&data;</root>", true);
    var text_bytes: usize = 0;
    var peak_capacity: usize = 0;
    while (true) switch (try reader.next()) {
        .event => |event| {
            peak_capacity = @max(peak_capacity, reader.memoryUsage().retained_capacity);
            switch (event) {
                .text => |text| text_bytes += text.bytes.len,
                else => {},
            }
        },
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, generated_bytes), text_bytes);
    try std.testing.expect(peak_capacity < 512 * 1024);
    try std.testing.expectEqual(@as(usize, 1), resolver.closes);
}

fn externalAllocationAttempt(allocator: std.mem.Allocator) !void {
    const resources = [_]TestExternalResource{
        .{ .system_id = "external.dtd", .bytes = "<!ENTITY message SYSTEM 'message.ent'>", .source_id = 51 },
        .{ .system_id = "message.ent", .bytes = "external", .source_id = 52 },
    };
    var resolver = TestResolver{ .resources = &resources, .max_read_len = 1 };
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{ .policy = .resolve, .resolver = resolver.resolver() };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'external.dtd'><root>&message;</root>", true);
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };
    try std.testing.expectEqual(@as(usize, 2), resolver.closes);
}

test "[integration] - [external allocation]: every parser allocation failure closes sources" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        externalAllocationAttempt,
        .{},
    );
}

test "[integration] - [rooted resolver]: reads beneath root and rejects escape and symlink paths" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.createDir(io, "schemas", .default_dir);
    try temporary.dir.writeFile(io, .{
        .sub_path = "schemas/document.dtd",
        .data = "<!ELEMENT root EMPTY>",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "outside.dtd",
        .data = "<!ELEMENT root ANY>",
    });
    try temporary.dir.symLink(io, "../outside.dtd", "schemas/link.dtd", .{});

    var rooted = xml.RootedFilesystemResolver.init(std.testing.allocator, io, temporary.dir);
    var options: xml.OptionsFor(DTD_CONFIG) = .{};
    options.resolver = .{
        .policy = .resolve,
        .resolver = rooted.resolver(),
        .document_base_id = "document.xml",
    };
    var reader = try xml.ReaderFor(DTD_CONFIG).init(std.testing.allocator, options);
    defer reader.deinit();
    try reader.feed("<!DOCTYPE root SYSTEM 'schemas/document.dtd'><root/>", true);
    while (true) switch (try reader.next()) {
        .event => {},
        .need_input => return error.UnexpectedNeedInput,
        .done => break,
    };

    try reader.reset(.retain_capacity);
    try reader.feed("<!DOCTYPE root SYSTEM '../outside.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.ResolverFailed, err);
            try std.testing.expectEqual(xml.DiagnosticCode.resolver_forbidden, reader.diagnostic().?.code);
            break;
        };
    }

    try reader.reset(.retain_capacity);
    try reader.feed("<!DOCTYPE root SYSTEM 'schemas/link.dtd'><root/>", true);
    while (true) {
        _ = reader.next() catch |err| {
            try std.testing.expectEqual(error.ResolverFailed, err);
            try std.testing.expectEqual(xml.DiagnosticCode.resolver_forbidden, reader.diagnostic().?.code);
            break;
        };
    }
}
