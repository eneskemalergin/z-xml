//! Public contract tests for the streaming reader.

const std = @import("std");
const xml = @import("z_xml");
const fixtures = @import("reader_fixtures");

const CORE_CONFIG = xml.Configs.XML10_UTF8_NO_DTD;
const FAST_CONFIG = xml.Configs.XML10_UTF8_NO_DTD_FAST;
const NS_CONFIG = xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD;
const GENERAL_CONFIG = xml.Configs.XML10_NO_DTD;
const GENERAL_FAST_CONFIG = xml.Configs.XML10_NO_DTD_FAST;
const CoreReader = xml.Reader(CORE_CONFIG);

const Summary = struct {
    const max_attribute_event_bytes = 4096;
    const max_name_event_bytes = 4096;
    const max_text_bytes = 4096;
    const max_misc_bytes = 4096;
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
    cdata_bytes: [max_misc_bytes]u8 = @splat(0),
    cdata_bytes_len: usize = 0,
    complete_comments: usize = 0,
    comment_bytes: [max_misc_bytes]u8 = @splat(0),
    comment_bytes_len: usize = 0,
    complete_processing_instructions: usize = 0,
    processing_instruction_active: bool = false,
    processing_instruction_bytes: [max_misc_bytes]u8 = @splat(0),
    processing_instruction_bytes_len: usize = 0,
    name_event_bytes: [max_name_event_bytes]u8 = @splat(0),
    name_event_bytes_len: usize = 0,
    namespace_declarations: usize = 0,
    namespace_event_bytes: [max_misc_bytes]u8 = @splat(0),
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
            .document_end => {
                self.sequence *%= 10;
                self.sequence +%= 4;
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

fn pushObserve(context: *PushContext, event: xml.Event(CORE_CONFIG)) xml.DrainControl {
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
    options: xml.Options(config),
    parts: []const []const u8,
) !Summary {
    const Reader = xml.Reader(config);
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
    options: xml.Options(config),
    input: []const u8,
) !Summary {
    const Reader = xml.Reader(config);
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
    options: xml.Options(config),
    input: []const u8,
    chunk_size: usize,
) !Summary {
    const Reader = xml.Reader(config);
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
    options: xml.Options(config),
    input: []const u8,
    seed: u64,
) !Summary {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const Reader = xml.Reader(config);
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
    options: xml.Options(config),
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
    const parts = [_][]const u8{fixtures.utf16le_bom};
    _ = try parseParts(GENERAL_CONFIG, allocator, .{}, &parts);
}

fn drainGeneralChunks(reader: *xml.Reader(GENERAL_FAST_CONFIG), input: []const u8) !void {
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
    const SliceReader = xml.SliceReader(CORE_CONFIG);
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
    options: xml.Options(FAST_CONFIG),
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
    options: xml.Options(FAST_CONFIG),
    parts: []const []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    const Reader = xml.Reader(FAST_CONFIG);
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
    const Reader = xml.Reader(GENERAL_FAST_CONFIG);
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
    options: xml.Options(FAST_CONFIG),
    input: []const u8,
    schedule: FailureChunkSchedule,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    diagnostic_offset: u64,
    related_offset: ?u64,
) !void {
    const Reader = xml.Reader(FAST_CONFIG);
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
    options: xml.Options(FAST_CONFIG),
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
    options: xml.Options(config),
    parts: []const []const u8,
    expected_error: anyerror,
    code: xml.DiagnosticCode,
    offset: u64,
    related_offset: ?u64,
) !void {
    const Reader = xml.Reader(config);
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
    options: xml.Options(config),
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

fn allocationStage5Parse(allocator: std.mem.Allocator) !void {
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

fn allocationStage6Parse(allocator: std.mem.Allocator) !void {
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
    const parts = [_][]const u8{fixtures.ns_churn};
    const summary = try parseParts(NS_CONFIG, allocator, .{}, &parts);
    try std.testing.expectEqual(@as(usize, 7), summary.starts);
    try std.testing.expectEqual(@as(usize, 7), summary.ends);
    try std.testing.expectEqual(@as(usize, 9), summary.namespace_declarations);
}

fn expectExpandedName(
    name: xml.Name(NS_CONFIG),
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

fn drainNamespace(reader: *xml.Reader(NS_CONFIG)) !Summary {
    var summary: Summary = .{};
    while (true) switch (try reader.next()) {
        .event => |event| try summary.observe(event),
        .need_input => return error.UnexpectedNeedInput,
        .done => return summary,
    };
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
        xml.Configs.XML11_NAMESPACES_VALIDATING,
    }) |config| {
        _ = xml.Reader(config);
        _ = xml.Event(config);
        _ = xml.Step(config);
        _ = xml.Options(config);
        _ = xml.Diagnostic(config);
        _ = xml.Name(config);
        _ = xml.Attribute(config);
        _ = xml.SliceReader(config);
        _ = xml.IoReader(config);
    }
}

test "config - excluded capabilities: specialized types omit impossible fields" {
    const fast_config = xml.Configs.XML10_UTF8_NO_DTD_FAST;
    const full_config = xml.Configs.XML10_NONVALIDATING;

    try std.testing.expect(!@hasField(xml.Event(fast_config), "document_type"));
    try std.testing.expect(@hasField(xml.Event(full_config), "document_type"));
    try std.testing.expect(
        @sizeOf(xml.Location(fast_config)) <
            @sizeOf(xml.Location(xml.Configs.XML10_UTF8_NO_DTD)),
    );
}

test "[failure] - [unimplemented profiles]: reject parsing without placeholder semantics" {
    inline for (.{
        xml.Configs.XML10_NONVALIDATING,
        xml.Configs.XML10_NAMESPACES_NONVALIDATING,
        xml.Configs.XML10_VALIDATING,
        xml.Configs.XML10_NAMESPACES_VALIDATING_DETAILED,
        xml.Configs.XML11_NAMESPACES_VALIDATING,
    }) |config| {
        const Reader = xml.Reader(config);
        var reader = try Reader.init(std.testing.allocator, .{});
        defer reader.deinit();
        try reader.feed("<root/>", true);

        try std.testing.expectError(error.UnsupportedFeature, reader.next());
        const diagnostic = reader.diagnostic().?;
        try std.testing.expectEqual(xml.DiagnosticCode.unsupported_stage, diagnostic.code);
        try std.testing.expectEqual(@as(u64, 0), diagnostic.primary.byte_offset);
        try std.testing.expectError(error.UnsupportedFeature, reader.next());
    }
}

test "reader - lifecycle: feed reset and deinit preserve state contract" {
    const Reader = xml.Reader(xml.Configs.XML10_UTF8_NO_DTD);
    var reader = try Reader.init(std.testing.allocator, .{});
    defer if (reader.lifecycle != .deinitialized) reader.deinit();

    try std.testing.expectEqual(xml.Lifecycle.ready, reader.lifecycle);
    try reader.feed("<root/>", true);
    try std.testing.expectEqual(xml.Lifecycle.producing, reader.lifecycle);
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
    try std.testing.expectEqual(xml.Lifecycle.ready, reader.lifecycle);
    try std.testing.expect(reader.diagnostic() == null);
    try std.testing.expect(reader.memoryUsage().retained_capacity > 0);

    try reader.reset(.release_memory);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);

    reader.deinit();
    try std.testing.expectEqual(xml.Lifecycle.deinitialized, reader.lifecycle);
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

test "success - element structure: nested siblings preserve names and syntax metadata" {
    try expectEvents("<root></root>", &.{
        .document_start,
        .{ .start_element = .{ .name = "root", .empty_element_syntax = false } },
        .{ .end_element = "root" },
        .document_end,
    });
    try expectEvents(fixtures.empty_explicit, &.{
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

test "streaming - element structure: all required chunk schedules agree" {
    const input = fixtures.nested;
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

test "streaming - explicit and empty fixture: all required chunk schedules agree" {
    const input = fixtures.empty_explicit;
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

test "fixture - stage 3 invalid corpus: registered structure cases have exact diagnostics" {
    try expectCoreFailureSchedules(
        fixtures.mismatched,
        error.InvalidXml,
        .mismatched_end_tag,
        14,
        6,
    );
    try expectCoreFailureSchedules(
        fixtures.unexpected_end,
        error.InvalidXml,
        .unexpected_end_tag,
        1,
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.unclosed,
        error.InvalidXml,
        .incomplete_input,
        20,
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.end_space,
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
    const SliceReader = xml.SliceReader(CORE_CONFIG);
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

    const IoReader = xml.IoReader(CORE_CONFIG);
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
    var input = try xml.IoReader(CORE_CONFIG).init(
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
    try xml.drainSlice(
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
    try xml.drainSlice(
        CORE_CONFIG,
        std.testing.allocator,
        .{},
        "<?pi?><r><!----><![CDATA[x]]></r>",
        &markup,
        pushObserve,
    );
    try std.testing.expectEqual(@as(usize, 7), markup.events);

    var attributed: PushContext = .{};
    try xml.drainSlice(
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
        xml.drainSlice(
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
    const Reader = xml.Reader(located_config);
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
    const Reader = xml.Reader(located_config);
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
    const Reader = xml.Reader(xml.Configs.XML10_UTF8_NO_DTD_FAST);
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
    const Reader = xml.Reader(xml.Configs.XML10_UTF8_NO_DTD);
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
    const Reader = xml.Reader(CORE_CONFIG);
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
        const Reader = xml.Reader(xml.Configs.XML10_UTF8_NO_DTD_FAST);
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

test "[integration] - [attributes]: fixture preserves source order and values" {
    try expectEvents(fixtures.attributes, &.{
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

    try expectSummarySchedules(fixtures.attributes, .{
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
    const SliceReader = xml.SliceReader(CORE_CONFIG);
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

test "[failure] - [attributes]: registered malformed fixtures have exact diagnostics" {
    try expectCoreFailureSchedules(
        fixtures.duplicate_attribute,
        error.InvalidXml,
        .duplicate_attribute,
        18,
        6,
    );
    try expectCoreFailureSchedules(
        fixtures.unquoted_attribute,
        error.InvalidXml,
        .malformed_attribute,
        12,
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.missing_equals,
        error.InvalidXml,
        .malformed_attribute,
        12,
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.attribute_lt,
        error.InvalidXml,
        .attribute_less_than,
        20,
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.truncated_attribute,
        error.InvalidXml,
        .incomplete_input,
        fixtures.truncated_attribute.len,
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

test "[integration] - [attribute normalization]: literal whitespace and references are semantic" {
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
    try expectEvents(fixtures.attribute_normalization, &expected_events);

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
        fixtures.mixed_content,
        "before inside after  tail",
        3,
        3,
        1,
    );
}

test "[property] - [references]: predefined and numeric values are semantic" {
    try expectSemanticSchedules(
        fixtures.predefined_entities,
        "<>&\"'",
        1,
        1,
        1,
    );
    try expectSemanticSchedules(
        fixtures.numeric_references,
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
    try expectEvents(fixtures.predefined_entities, &predefined_events);

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
    try expectEvents(fixtures.numeric_references, &numeric_events);
}

test "[property] - [UTF-8]: BOM and scalar widths survive every split" {
    try expectSemanticSchedules(fixtures.utf8_bom, "é🙂", 1, 1, 0);
    try expectSemanticSchedules(
        fixtures.utf8_boundaries,
        "ࠀ𐀀􏿿",
        1,
        1,
        0,
    );
    try expectSemanticSchedules(
        fixtures.unicode_text,
        "ASCII, e acute: é, CJK: 漢字, emoji: 🙂",
        1,
        1,
        0,
    );
}

test "[property] - [UTF-16]: byte order code units and surrogates survive every split" {
    const little_parts = [_][]const u8{fixtures.utf16le_bom};
    const little = try parseParts(GENERAL_CONFIG, std.testing.allocator, .{}, &little_parts);
    try std.testing.expectEqual(xml.SourceEncoding.utf16_le, little.source_encoding);
    try std.testing.expectEqualStrings("UTF-16", little.declared_encoding[0..little.declared_encoding_len]);
    try std.testing.expectEqualStrings("λ🙂", little.text_bytes[0..little.text_bytes_len]);
    try expectSummarySchedulesWithOptions(GENERAL_CONFIG, .{}, fixtures.utf16le_bom, little);

    const big_parts = [_][]const u8{fixtures.utf16be_bom};
    const big = try parseParts(GENERAL_CONFIG, std.testing.allocator, .{}, &big_parts);
    try std.testing.expectEqual(xml.SourceEncoding.utf16_be, big.source_encoding);
    try std.testing.expectEqualStrings("UTF-16", big.declared_encoding[0..big.declared_encoding_len]);
    try std.testing.expectEqualStrings("λ🙂", big.text_bytes[0..big.text_bytes_len]);
    try expectSummarySchedulesWithOptions(GENERAL_CONFIG, .{}, fixtures.utf16be_bom, big);
}

test "[property] - [general UTF-8]: direct source path agrees across schedules" {
    const input = "<根 a='é'>x\r\ny🙂</根>";
    const parts = [_][]const u8{input};
    const summary = try parseParts(GENERAL_CONFIG, std.testing.allocator, .{}, &parts);
    try std.testing.expectEqual(xml.SourceEncoding.utf8, summary.source_encoding);
    try std.testing.expectEqualStrings("x\ny🙂", summary.text_bytes[0..summary.text_bytes_len]);
    try expectSummarySchedulesWithOptions(GENERAL_CONFIG, .{}, input, summary);
}

test "[failure] - [UTF-16]: odd bytes and unpaired surrogates have stable source offsets" {
    try expectGeneralFailureSchedules(
        fixtures.utf16le_odd_byte,
        .malformed_encoding,
        fixtures.utf16le_odd_byte.len - 1,
    );
    try expectGeneralFailureSchedules(
        fixtures.utf16le_unpaired_high,
        .malformed_encoding,
        14,
    );
    try expectGeneralFailureSchedules(
        fixtures.utf16be_unpaired_low,
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

    try expectGeneralFailureSchedules(
        fixtures.declared_utf16,
        .encoding_mismatch,
        std.mem.indexOf(u8, fixtures.declared_utf16, "UTF-16").?,
    );
}

test "[integration] - [buffered UTF-16]: one-byte source reads preserve semantics" {
    var io_buffer: [5]u8 = undefined;
    var source: std.testing.Reader = .init(&io_buffer, &.{.{ .buffer = fixtures.utf16le_bom }});
    source.artificial_limit = .limited(1);
    var input = try xml.IoReader(GENERAL_CONFIG).init(
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

    var reader = try xml.Reader(GENERAL_FAST_CONFIG).init(std.testing.allocator, .{});
    defer reader.deinit();
    try drainGeneralChunks(&reader, encoded);
    const capacity = reader.memoryUsage().decoder_capacity;
    try std.testing.expectEqual(@as(usize, 2 * 16 * 1024), capacity);

    try reader.reset(.retain_capacity);
    try drainGeneralChunks(&reader, fixtures.utf16le_bom);
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
    const Reader = xml.Reader(GENERAL_CONFIG);
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
    try expectSemanticSchedules(fixtures.cr_line_endings, "one\ntwo\n", 1, 1, 0);
    try expectSemanticSchedules(fixtures.crlf_line_endings, "one\ntwo\n", 1, 1, 0);
}

test "[integration] - [buffered UTF-8]: one-byte source reads preserve semantics" {
    const source_bytes = "<文 属性='a&#9;b'>é\r\n🙂&amp;</文>";
    var io_buffer: [5]u8 = undefined;
    var source: std.testing.Reader = .init(&io_buffer, &.{.{ .buffer = source_bytes }});
    source.artificial_limit = .limited(1);

    var input = try xml.IoReader(CORE_CONFIG).init(
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

test "[integration] - [buffered markup]: one-byte source reads preserve stage 6 semantics" {
    var io_buffer: [7]u8 = undefined;
    var source: std.testing.Reader = .init(
        &io_buffer,
        &.{.{ .buffer = fixtures.prolog_epilog_misc }},
    );
    source.artificial_limit = .limited(1);

    var input = try xml.IoReader(CORE_CONFIG).init(
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
    try expectEvents(fixtures.unicode_names, &unicode_events);
    try expectSemanticSchedules(fixtures.unicode_names, "", 2, 2, 1);

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
    try expectEvents(fixtures.name_characters, &name_character_events);
    try expectSemanticSchedules(fixtures.name_characters, "", 5, 5, 0);
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
    const malformed_offset = std.mem.indexOfScalar(
        u8,
        fixtures.malformed_character_reference,
        'Z',
    ).?;
    try expectCoreFailureSchedules(
        fixtures.malformed_character_reference,
        error.InvalidXml,
        .malformed_reference,
        @intCast(malformed_offset),
        null,
    );
    inline for (.{
        fixtures.zero_character_reference,
        fixtures.surrogate_character_reference,
        fixtures.out_of_range_character_reference,
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
    const undefined_offset = std.mem.indexOfScalar(u8, fixtures.undefined_entity, '&').?;
    try expectCoreFailureSchedules(
        fixtures.undefined_entity,
        error.InvalidXml,
        .undeclared_entity,
        @intCast(undefined_offset),
        null,
    );
    const truncated_offset = std.mem.indexOf(
        u8,
        fixtures.truncated_entity[1..],
        "<",
    ).? + 1;
    try expectCoreFailureSchedules(
        fixtures.truncated_entity,
        error.InvalidXml,
        .malformed_reference,
        @intCast(truncated_offset),
        null,
    );
}

test "[failure] - [character data]: literal CDATA close is rejected across schedules" {
    const close = std.mem.lastIndexOf(u8, fixtures.cdata_close_in_text, "]]>").?;
    try expectCoreFailureSchedules(
        fixtures.cdata_close_in_text,
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
        .{ .input = fixtures.utf8_lone_continuation, .offset = 6 },
        .{ .input = fixtures.utf8_overlong, .offset = 6 },
        .{ .input = fixtures.utf8_truncated, .offset = 8 },
        .{ .input = fixtures.utf8_surrogate, .offset = 7 },
        .{ .input = fixtures.utf8_out_of_range, .offset = 7 },
        .{ .input = fixtures.utf8_invalid_byte, .offset = 6 },
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
    inline for (.{ fixtures.literal_null, fixtures.literal_control }) |input| {
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
    const Reader = xml.Reader(located_config);
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

test "[integration] - [stage 6 locations]: declaration span and PI target lifetime are exact" {
    const located_config = xml.Configs.XML10_UTF8_NO_DTD_LOCATED;
    const Reader = xml.Reader(located_config);
    var options: xml.Options(located_config) = .{};
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
    var core_options: xml.Options(CORE_CONFIG) = .{};
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

    var failure_options: xml.Options(FAST_CONFIG) = .{};
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
    var options: xml.Options(FAST_CONFIG) = .{};
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

test "[failure] - [stage 5 storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationStage5Parse,
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

test "[unit] - [stage 5 reset]: pending scalar, reference, and CR state is discarded" {
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
    const parts = [_][]const u8{fixtures.declaration};
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
    try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, fixtures.declaration, expected);

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

test "[property] - [miscellaneous markup]: logical events agree across schedules" {
    {
        const parts = [_][]const u8{fixtures.prolog_epilog_misc};
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
            fixtures.prolog_epilog_misc,
            expected,
        );
    }
    {
        const parts = [_][]const u8{fixtures.comment_edges};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqualStrings(
            " hyphen-allowed empty",
            expected.comment_bytes[0..expected.comment_bytes_len],
        );
        try std.testing.expectEqual(@as(usize, 2), expected.complete_comments);
        try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, fixtures.comment_edges, expected);
    }
    {
        const parts = [_][]const u8{fixtures.processing_instruction};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqualStrings(
            "before\x00data\xffinside\x00more data\xffafter\x00\xff",
            expected.processing_instruction_bytes[0..expected.processing_instruction_bytes_len],
        );
        try std.testing.expectEqual(@as(usize, 3), expected.complete_processing_instructions);
        try expectSummarySchedulesWithOptions(
            CORE_CONFIG,
            .{},
            fixtures.processing_instruction,
            expected,
        );
    }
    {
        const parts = [_][]const u8{fixtures.cdata};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        const text = "<not-markup>&not-an-entity;";
        try std.testing.expectEqualStrings(text, expected.text_bytes[0..expected.text_bytes_len]);
        try std.testing.expectEqualStrings(text, expected.cdata_bytes[0..expected.cdata_bytes_len]);
        try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, fixtures.cdata, expected);
    }
    {
        const parts = [_][]const u8{fixtures.shape_records};
        const expected = try parseParts(CORE_CONFIG, std.testing.allocator, .{}, &parts);
        try std.testing.expectEqual(@as(usize, 7), expected.starts);
        try std.testing.expectEqual(@as(usize, 10), expected.attributes);
        try std.testing.expectEqualStrings(
            "tail <raw>",
            expected.cdata_bytes[0..expected.cdata_bytes_len],
        );
        try expectSummarySchedulesWithOptions(CORE_CONFIG, .{}, fixtures.shape_records, expected);
    }
}

test "[failure] - [declaration]: syntax placement version and encoding are distinct" {
    const order_offset = std.mem.indexOf(u8, fixtures.declaration_attribute_order, "encoding").?;
    try expectCoreFailureSchedules(
        fixtures.declaration_attribute_order,
        error.InvalidXml,
        .malformed_declaration,
        @intCast(order_offset),
        null,
    );
    const misplaced_offset = std.mem.indexOf(u8, fixtures.declaration_not_first, "<?xml").?;
    try expectCoreFailureSchedules(
        fixtures.declaration_not_first,
        error.InvalidXml,
        .misplaced_xml_declaration,
        @intCast(misplaced_offset),
        null,
    );
    const duplicate_offset = std.mem.lastIndexOf(u8, fixtures.duplicate_declaration, "<?xml").?;
    try expectCoreFailureSchedules(
        fixtures.duplicate_declaration,
        error.InvalidXml,
        .misplaced_xml_declaration,
        @intCast(duplicate_offset),
        null,
    );
    const version_offset = std.mem.indexOf(u8, fixtures.unsupported_version, "2.0").?;
    try expectCoreFailureSchedules(
        fixtures.unsupported_version,
        error.InvalidXml,
        .unsupported_version,
        @intCast(version_offset),
        null,
    );
    const encodings = [_]struct {
        input: []const u8,
        value: []const u8,
    }{
        .{ .input = fixtures.declared_utf16, .value = "UTF-16" },
        .{ .input = fixtures.ascii_declared, .value = "US-ASCII" },
        .{ .input = fixtures.iso_8859_1, .value = "ISO-8859-1" },
        .{ .input = fixtures.declared_ascii_high_byte, .value = "US-ASCII" },
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

test "[failure] - [miscellaneous markup]: malformed forms retain exact categories" {
    const comment_offset = std.mem.indexOf(u8, fixtures.comment_double_hyphen, "-- comment").? + 2;
    try expectCoreFailureSchedules(
        fixtures.comment_double_hyphen,
        error.InvalidXml,
        .malformed_comment,
        @intCast(comment_offset),
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.unclosed_comment,
        error.InvalidXml,
        .unclosed_comment,
        @intCast(fixtures.unclosed_comment.len),
        null,
    );
    const pi_offset = std.mem.indexOf(u8, fixtures.reserved_pi_target, "<?XmL").?;
    try expectCoreFailureSchedules(
        fixtures.reserved_pi_target,
        error.InvalidXml,
        .reserved_processing_instruction_target,
        @intCast(pi_offset),
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.unclosed_cdata,
        error.InvalidXml,
        .unclosed_cdata,
        @intCast(fixtures.unclosed_cdata.len),
        null,
    );
    const misplaced_doctype = std.mem.indexOf(u8, fixtures.doctype_after_root, "<!DOCTYPE").?;
    try expectCoreFailureSchedules(
        fixtures.doctype_after_root,
        error.InvalidXml,
        .misplaced_doctype,
        @intCast(misplaced_doctype),
        null,
    );
    try expectCoreFailureSchedules(
        fixtures.multiple_doctypes,
        error.UnsupportedFeature,
        .unsupported_doctype,
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

test "[failure] - [stage 6 characters]: malformed UTF-8 and forbidden bytes win in data" {
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

test "[edge] - [miscellaneous fragments]: semantic limits preserve complete values" {
    var options: xml.Options(CORE_CONFIG) = .{};
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

    var target_options: xml.Options(FAST_CONFIG) = .{};
    target_options.limits.max_processing_instruction_target_bytes = 3;
    try expectCoreFailureSchedulesWithOptions(
        target_options,
        "<?abcd?><r/>",
        error.LimitExceeded,
        .processing_instruction_target_limit,
        5,
        null,
    );

    var delimiter_options: xml.Options(FAST_CONFIG) = .{};
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

test "[failure] - [stage 6 storage]: every allocation failure cleans up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationStage6Parse,
        .{},
    );
}

test "[property] - [miscellaneous normalization]: UTF-8 CRLF and delimiter suffixes are semantic" {
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

test "[property] - [miscellaneous fragments]: contiguous UTF-8 stays in borrowed runs" {
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
    var short_target_options: xml.Options(FAST_CONFIG) = .{};
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

    var options: xml.Options(CORE_CONFIG) = .{};
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

    var unicode_target_options: xml.Options(FAST_CONFIG) = .{};
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

    var delimiter_options: xml.Options(CORE_CONFIG) = .{};
    delimiter_options.limits.max_partial_token_bytes = 3;
    const comment_parts = [_][]const u8{"<r><!----></r>"};
    _ = try parseParts(
        CORE_CONFIG,
        std.testing.allocator,
        delimiter_options,
        &comment_parts,
    );

    var cdata_delimiter_options: xml.Options(FAST_CONFIG) = .{};
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

    var declaration_options: xml.Options(FAST_CONFIG) = .{};
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

    var bracket_options: xml.Options(CORE_CONFIG) = .{};
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

    var fragment_options: xml.Options(FAST_CONFIG) = .{};
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

test "[unit] - [stage 6 reset]: pending declaration and delimiter state is discarded" {
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
    var options: xml.Options(FAST_CONFIG) = .{};
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
    var options: xml.Options(FAST_CONFIG) = .{};
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
    var options: xml.Options(FAST_CONFIG) = .{};
    options.limits.max_attribute_name_bytes = 3;
    const Reader = xml.Reader(FAST_CONFIG);
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
    var options: xml.Options(xml.Configs.XML10_UTF8_NO_DTD_FAST) = .{};
    options.limits.max_partial_token_bytes = 3;
    const Reader = xml.Reader(xml.Configs.XML10_UTF8_NO_DTD_FAST);
    var reader = try Reader.init(std.testing.allocator, options);
    defer reader.deinit();

    try reader.feed("<root/>", true);
    _ = try reader.next();
    try std.testing.expectError(error.LimitExceeded, reader.next());
    try std.testing.expectEqual(xml.DiagnosticCode.partial_token_limit, reader.diagnostic().?.code);
    try std.testing.expectEqual(@as(u64, 4), reader.diagnostic().?.primary.byte_offset);
}

test "limit - closing name: partial-token limit precedes a later mismatch" {
    var options: xml.Options(FAST_CONFIG) = .{};
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
    var options: xml.Options(FAST_CONFIG) = .{};
    options.limits.max_depth = 2;

    {
        const Reader = xml.Reader(FAST_CONFIG);
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

    const Reader = xml.Reader(FAST_CONFIG);
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
    var at_limit: xml.Options(FAST_CONFIG) = .{};
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
        const LimitedReader = xml.Reader(FAST_CONFIG);
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

    const Reader = xml.Reader(FAST_CONFIG);
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
    var options: xml.Options(FAST_CONFIG) = .{};
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
    var options: xml.Options(CORE_CONFIG) = .{};
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

    var at_options: xml.Options(CORE_CONFIG) = .{};
    at_options.limits.max_retained_bytes = retained;
    var at = try CoreReader.init(std.testing.allocator, at_options);
    defer at.deinit();
    try at.feed(MANY_ATTRIBUTES, true);
    _ = try drainCore(&at);
    try std.testing.expectEqual(retained, at.memoryUsage().retained_capacity);
    try at.reset(.retain_capacity);
    try std.testing.expectEqual(retained, at.memoryUsage().retained_capacity);

    var over_options: xml.Options(CORE_CONFIG) = .{};
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
    var options: xml.Options(CORE_CONFIG) = .{};
    options.limits.max_attributes_per_element = 2;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var reader = try CoreReader.init(failing.allocator(), options);
        defer reader.deinit();

        var plateau: usize = 0;
        var phase: usize = 0;
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
            if (phase < 3) {
                plateau = @max(plateau, retained);
            } else {
                try std.testing.expect(retained <= plateau);
            }
            phase += 1;

            if (iteration % 127 == 126) {
                try reader.reset(.release_memory);
                try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
                plateau = 0;
                phase = 0;
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

fn arbitraryOutcome(input: []const u8, seed: ?u64) !FuzzOutcome {
    var options: xml.Options(FAST_CONFIG) = .{};
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

    const Reader = xml.Reader(FAST_CONFIG);
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
    const whole = try arbitraryOutcome(input, null);
    try std.testing.expectEqual(whole, try arbitraryOutcome(input, 0x7a786d6c));
}

test "[fuzz] - [arbitrary bytes]: parsing is bounded and schedule invariant" {
    try std.testing.fuzz({}, fuzzArbitraryBytes, .{
        .corpus = &.{
            "<root/>",
            "<root a='&amp;'>text</root>",
            "<root><item></root>",
            "<!DOCTYPE root><root/>",
            "\xef\xbb\xbf<root>\xf0\x9f\x99\x82</root>",
            "<root>\xc0\x80</root>",
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
        const whole = try arbitraryOutcome(storage[0..len], null);
        try std.testing.expectEqual(
            whole,
            try arbitraryOutcome(storage[0..len], iteration + 1),
        );
    }
}

test "[failure] - [reader initialization]: zero required limits fail without allocation" {
    const Reader = xml.Reader(xml.Configs.XML10_UTF8_NO_DTD);
    var options: xml.Options(xml.Configs.XML10_UTF8_NO_DTD) = .{};
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

    const NamespaceReader = xml.Reader(NS_CONFIG);
    var namespace_options: xml.Options(NS_CONFIG) = .{};
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
}

test "[unit] - [namespace expansion]: declarations and ordinary attributes are distinct" {
    const Reader = xml.SliceReader(NS_CONFIG);
    var reader = try Reader.init(std.testing.allocator, .{}, fixtures.ns_default_attributes);
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
    var reader = try xml.Reader(NS_CONFIG).init(std.testing.allocator, .{});
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
    const inputs = [_][]const u8{
        fixtures.ns_rebinding,
        fixtures.ns_default_undeclare,
        fixtures.ns_xml_prefix,
        fixtures.ns_equivalent_uri,
    };
    for (inputs) |input| {
        const parts = [_][]const u8{input};
        _ = try parseParts(NS_CONFIG, std.testing.allocator, .{}, &parts);
    }

    var reader = try xml.SliceReader(NS_CONFIG).init(
        std.testing.allocator,
        .{},
        fixtures.ns_rebinding,
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

    var undeclare_reader = try xml.SliceReader(NS_CONFIG).init(
        std.testing.allocator,
        .{},
        fixtures.ns_default_undeclare,
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

    var options: xml.Options(NS_CONFIG) = .{};
    options.namespace_limits.max_active_bindings = 1;
    options.namespace_limits.max_binding_bytes = 2;
    var static_reader = try xml.Reader(NS_CONFIG).init(std.testing.allocator, options);
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
    var reader = try xml.SliceReader(NS_CONFIG).init(
        std.testing.allocator,
        .{},
        fixtures.ns_equivalent_uri,
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

test "[property] - [namespace fixtures]: every valid fixture agrees across schedules" {
    inline for (.{
        fixtures.ns_default,
        fixtures.ns_prefixed,
        fixtures.ns_rebinding,
        fixtures.ns_default_attributes,
        fixtures.ns_xml_prefix,
        fixtures.ns_default_undeclare,
        fixtures.ns_equivalent_uri,
        fixtures.ns_churn,
    }) |input| {
        const parts = [_][]const u8{input};
        const expected = try parseParts(NS_CONFIG, std.testing.allocator, .{}, &parts);
        try expectSummarySchedulesWithOptions(NS_CONFIG, .{}, input, expected);
    }
}

test "[failure] - [namespace fixtures]: invalid cases have stable diagnostics across schedules" {
    const Case = struct {
        input: []const u8,
        code: xml.DiagnosticCode,
        primary: usize,
        related: ?usize = null,
    };
    const cases = [_]Case{
        .{ .input = fixtures.ns_unbound_element, .code = .unbound_prefix, .primary = 1 },
        .{ .input = fixtures.ns_unbound_attribute, .code = .unbound_prefix, .primary = 6 },
        .{
            .input = fixtures.ns_bad_xml_binding,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.indexOf(u8, fixtures.ns_bad_xml_binding, "xmlns:xml").?,
        },
        .{
            .input = fixtures.ns_bad_xmlns_binding,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.indexOf(u8, fixtures.ns_bad_xmlns_binding, "xmlns:xmlns").?,
        },
        .{ .input = fixtures.ns_xmlns_element, .code = .reserved_namespace_name, .primary = 1 },
        .{
            .input = fixtures.ns_duplicate_expanded,
            .code = .duplicate_expanded_attribute,
            .primary = std.mem.indexOf(u8, fixtures.ns_duplicate_expanded, "b:value").?,
            .related = std.mem.indexOf(u8, fixtures.ns_duplicate_expanded, "a:value").?,
        },
        .{ .input = fixtures.ns_multiple_colons, .code = .malformed_qname, .primary = 4 },
        .{
            .input = fixtures.ns_prefix_undeclare,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.lastIndexOf(u8, fixtures.ns_prefix_undeclare, "xmlns:p").?,
        },
        .{
            .input = fixtures.ns_bad_default_uri,
            .code = .illegal_namespace_declaration,
            .primary = std.mem.indexOf(u8, fixtures.ns_bad_default_uri, "xmlns").?,
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
        var options: xml.Options(NS_CONFIG) = .{};
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
        var options: xml.Options(NS_CONFIG) = .{};
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
        var options: xml.Options(NS_CONFIG) = .{};
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
        var options: xml.Options(NS_CONFIG) = .{};
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
        var options: xml.Options(NS_CONFIG) = .{};
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
        var options: xml.Options(NS_CONFIG) = .{};
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
        var options: xml.Options(NS_CONFIG) = .{};
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
    var reader = try xml.Reader(NS_CONFIG).init(std.testing.allocator, .{});
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
        @sizeOf(xml.Reader(xml.Configs.XML10_UTF8_NO_DTD_FAST)) <
            @sizeOf(xml.Reader(xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD_FAST)),
    );
    var reader = try xml.Reader(xml.Configs.XML10_UTF8_NO_DTD_FAST).init(
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
    var reader = try xml.Reader(NS_CONFIG).init(failing.allocator(), .{});
    defer reader.deinit();

    try reader.feed(fixtures.ns_churn, true);
    try std.testing.expectEqual(@as(usize, 7), (try drainNamespace(&reader)).starts);
    try std.testing.expect(failing.alloc_index > 0);

    try reader.reset(.retain_capacity);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try reader.feed(fixtures.ns_churn, true);
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

    var reader = try xml.Reader(NS_CONFIG).init(std.testing.allocator, .{});
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
    var limited_options: xml.Options(NS_CONFIG) = .{};
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
