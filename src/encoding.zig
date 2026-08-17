//! Source-encoding types and the bounded caller-transcoder bridge.

const std = @import("std");

/// Source encoding selected for one parsed entity.
pub const SourceEncoding = enum {
    utf8,
    utf16_le,
    utf16_be,
    other,
};

/// One caller-transcoder result.
pub const TranscodeStep = union(enum) {
    progress: struct {
        consumed: usize,
        produced: usize,
    },
    need_input,
    need_output,
    malformed: usize,
    unsupported,
};

/// Failure caused by a caller transcoder violating its bounded-buffer contract.
pub const TranscoderError = error{InvalidResult};

/// Caller-owned incremental converter from source bytes to UTF-8.
pub const Transcoder = struct {
    context: ?*anyopaque,
    runFn: *const fn (
        context: ?*anyopaque,
        input: []const u8,
        final: bool,
        output: []u8,
    ) TranscodeStep,

    /// Converts one bounded input and output window and validates callback progress.
    pub fn run(
        self: Transcoder,
        input: []const u8,
        final: bool,
        output: []u8,
    ) TranscoderError!TranscodeStep {
        const step = self.runFn(self.context, input, final, output);
        switch (step) {
            .progress => |progress| {
                if (progress.consumed > input.len or progress.produced > output.len or
                    (progress.consumed == 0 and progress.produced == 0))
                {
                    return error.InvalidResult;
                }
            },
            .malformed => |offset| if (offset > input.len) return error.InvalidResult,
            .need_input, .need_output, .unsupported => {},
        }
        return step;
    }
};

fn testLatin1(
    context: ?*anyopaque,
    input: []const u8,
    final: bool,
    output: []u8,
) TranscodeStep {
    _ = final;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    if (input.len == 0) return .need_input;
    if (input[0] == 0xe9) {
        if (output.len < 2) return .need_output;
        output[0] = 0xc3;
        output[1] = 0xa9;
        return .{ .progress = .{ .consumed = 1, .produced = 2 } };
    }
    if (output.len == 0) return .need_output;
    output[0] = input[0];
    return .{ .progress = .{ .consumed = 1, .produced = 1 } };
}

fn testInvalid(
    _: ?*anyopaque,
    input: []const u8,
    _: bool,
    output: []u8,
) TranscodeStep {
    return .{ .progress = .{ .consumed = input.len + 1, .produced = output.len + 1 } };
}

// --- Tests ---

test "transcoder bridge accepts bounded UTF-8 progress and rejects invalid counts" {
    var calls: usize = 0;
    const transcoder: Transcoder = .{ .context = &calls, .runFn = testLatin1 };
    var output: [4]u8 = undefined;
    const step = try transcoder.run("\xe9", true, &output);
    try std.testing.expectEqual(@as(usize, 1), step.progress.consumed);
    try std.testing.expectEqual(@as(usize, 2), step.progress.produced);
    try std.testing.expectEqualStrings("é", output[0..2]);
    try std.testing.expectEqual(@as(usize, 1), calls);

    const short = try transcoder.run("\xe9", false, output[0..1]);
    try std.testing.expect(short == .need_output);
    const empty = try transcoder.run("x", false, output[0..0]);
    try std.testing.expect(empty == .need_output);

    const invalid: Transcoder = .{ .context = null, .runFn = testInvalid };
    try std.testing.expectError(error.InvalidResult, invalid.run("x", true, &output));
}
