//! Public contract tests for the streaming reader.

const std = @import("std");
const xml = @import("z_xml");
const fixtures = @import("stage3_fixtures");

const CORE_CONFIG = xml.Configs.XML10_UTF8_NO_DTD;
const FAST_CONFIG = xml.Configs.XML10_UTF8_NO_DTD_FAST;
const CoreReader = xml.Reader(CORE_CONFIG);

const Summary = struct {
    sequence: u64 = 0,
    starts: usize = 0,
    ends: usize = 0,
    empty_starts: usize = 0,
    name_bytes: usize = 0,

    fn observe(self: *Summary, event: anytype) !void {
        switch (event) {
            .document_start => self.sequence = self.sequence * 10 + 1,
            .start_element => |start| {
                self.sequence = self.sequence * 10 + 2;
                self.starts += 1;
                self.empty_starts += @intFromBool(start.empty_element_syntax);
                self.name_bytes += start.name.raw.len;
            },
            .end_element => |end| {
                self.sequence = self.sequence * 10 + 3;
                self.ends += 1;
                self.name_bytes += end.name.raw.len;
            },
            .document_end => self.sequence = self.sequence * 10 + 4,
            else => return error.UnexpectedEvent,
        }
    }
};

const ExpectedEvent = union(enum) {
    document_start,
    start_element: struct {
        name: []const u8,
        empty_element_syntax: bool,
    },
    end_element: []const u8,
    document_end,
};

const PushContext = struct {
    events: usize = 0,
    cancel_after: ?usize = null,
};

fn pushObserve(context: *PushContext, event: xml.Event(CORE_CONFIG)) xml.DrainControl {
    _ = event;
    context.events += 1;
    if (context.cancel_after == context.events) return .cancel;
    return .continue_parsing;
}

fn parseParts(allocator: std.mem.Allocator, parts: []const []const u8) !Summary {
    var reader = try CoreReader.init(allocator, .{});
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

fn parseOneByteChunks(allocator: std.mem.Allocator, input: []const u8) !Summary {
    var reader = try CoreReader.init(allocator, .{});
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
    allocator: std.mem.Allocator,
    input: []const u8,
    chunk_size: usize,
) !Summary {
    var reader = try CoreReader.init(allocator, .{});
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
    allocator: std.mem.Allocator,
    input: []const u8,
    seed: u64,
) !Summary {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var reader = try CoreReader.init(allocator, .{});
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
                        },
                        else => return error.UnexpectedEvent,
                    },
                    .end_element => |end| switch (expected[index]) {
                        .end_element => |wanted| {
                            try std.testing.expectEqualStrings(wanted, end.name.raw);
                        },
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
    try expectCoreFailure(.{}, input, expected_error, code, offset, related_offset);
    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try expectCoreFailureParts(
            .{},
            &parts,
            expected_error,
            code,
            offset,
            related_offset,
        );
    }
    inline for (.{ 1, 2, 3, 5, 7 }) |chunk_size| {
        try expectCoreFailureChunked(
            .{},
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
            .{},
            input,
            .{ .random = seed },
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

test "config - representative profiles: compile specialized public types" {
    inline for (.{
        xml.Configs.XML10_UTF8_NO_DTD_FAST,
        xml.Configs.XML10_UTF8_NO_DTD,
        xml.Configs.XML10_UTF8_NO_DTD_LOCATED,
        xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD,
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
    const expected = try parseParts(std.testing.allocator, &whole_parts);

    try std.testing.expectEqual(@as(u32, 1234), expected.sequence);
    try std.testing.expectEqual(@as(usize, 1), expected.starts);
    try std.testing.expectEqual(@as(usize, 1), expected.ends);

    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try std.testing.expectEqual(expected, try parseParts(std.testing.allocator, &parts));
    }
    try std.testing.expectEqual(expected, try parseOneByteChunks(std.testing.allocator, input));
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
    const expected = try parseParts(std.testing.allocator, &whole_parts);

    try std.testing.expectEqual(@as(u64, 1222233334), expected.sequence);
    try std.testing.expectEqual(@as(usize, 4), expected.starts);
    try std.testing.expectEqual(@as(usize, 4), expected.ends);
    try std.testing.expectEqual(@as(usize, 1), expected.empty_starts);
    try std.testing.expectEqual(@as(usize, 52), expected.name_bytes);

    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try std.testing.expectEqual(expected, try parseParts(std.testing.allocator, &parts));
    }
    try std.testing.expectEqual(expected, try parseOneByteChunks(std.testing.allocator, input));
    inline for (.{ 2, 3, 5, 7, 11 }) |chunk_size| {
        try std.testing.expectEqual(
            expected,
            try parseFixedChunks(std.testing.allocator, input, chunk_size),
        );
    }
    for (0..32) |seed| {
        try std.testing.expectEqual(
            expected,
            try parseRandomChunks(std.testing.allocator, input, seed),
        );
    }
}

test "streaming - explicit and empty fixture: all required chunk schedules agree" {
    const input = fixtures.empty_explicit;
    const whole_parts = [_][]const u8{input};
    const expected = try parseParts(std.testing.allocator, &whole_parts);

    for (1..input.len) |split| {
        const parts = [_][]const u8{ input[0..split], input[split..] };
        try std.testing.expectEqual(expected, try parseParts(std.testing.allocator, &parts));
    }
    try std.testing.expectEqual(expected, try parseOneByteChunks(std.testing.allocator, input));
    inline for (.{ 2, 3, 5, 7, 11 }) |chunk_size| {
        try std.testing.expectEqual(
            expected,
            try parseFixedChunks(std.testing.allocator, input, chunk_size),
        );
    }
    for (0..8) |seed| {
        try std.testing.expectEqual(
            expected,
            try parseRandomChunks(std.testing.allocator, input, seed),
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
    var slice = try SliceReader.init(std.testing.allocator, .{}, "<root><item/></root>");
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
}

test "adapter - std Io Reader: greedy buffered refill handles one-byte source reads" {
    var io_buffer: [3]u8 = undefined;
    var source: std.testing.Reader = .init(&io_buffer, &.{
        .{ .buffer = "<root><item/></root>" },
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

test "boundary - stage ownership: attributes and text remain unsupported" {
    try expectCoreFailure(
        .{},
        "<root key='value'/>",
        error.UnsupportedFeature,
        .unsupported_stage,
        6,
        null,
    );
    try expectCoreFailure(
        .{},
        "<root>text</root>",
        error.UnsupportedFeature,
        .unsupported_stage,
        6,
        null,
    );
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

    try reader.feed("<root/>", true);
    _ = try drainCore(&reader);
    try std.testing.expect(reader.memoryUsage().retained_capacity > 1);

    try reader.reset(.retain_capacity);
    try std.testing.expectEqual(@as(usize, 0), reader.memoryUsage().retained_capacity);
}

test "reader - initialization: invalid limits fail without allocation" {
    const Reader = xml.Reader(xml.Configs.XML10_UTF8_NO_DTD);
    var options: xml.Options(xml.Configs.XML10_UTF8_NO_DTD) = .{};
    options.limits.max_depth = 0;

    try std.testing.expectError(error.InvalidOptions, Reader.init(std.testing.allocator, options));

    options = .{};
    options.limits.max_open_name_bytes = 0;
    try std.testing.expectError(error.InvalidOptions, Reader.init(std.testing.allocator, options));
}
