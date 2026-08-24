//! Source-encoding types and the bounded caller-transcoder bridge.

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
    cancelled,
};

/// Failure caused by a caller transcoder violating its bounded-buffer contract.
pub const TranscoderError = error{InvalidResult};

/// Caller-owned incremental converter from source bytes to UTF-8.
///
/// Reader calls contain at most 255 input bytes. The output and source-advance
/// slices have equal length.
/// Each progress result consumes and produces at least one byte. The callback
/// fills one source-advance entry per produced byte; their sum must equal the
/// consumed count, and advances occur after the corresponding output byte.
/// `need_input` with empty final input finishes the source. A callback reports
/// malformed final input instead of requesting more bytes that cannot arrive.
/// `need_output` reports that the next UTF-8 output does not fit. `malformed`
/// gives an offset in the supplied input. `unsupported` and `cancelled` stop
/// decoding without progress.
pub const Transcoder = struct {
    context: ?*anyopaque,
    runFn: *const fn (
        context: ?*anyopaque,
        input: []const u8,
        final: bool,
        output: []u8,
        source_advances: []u8,
    ) TranscodeStep,

    /// Converts one bounded input and output window and validates callback progress.
    pub fn run(
        self: Transcoder,
        input: []const u8,
        final: bool,
        output: []u8,
        source_advances: []u8,
    ) TranscoderError!TranscodeStep {
        if (source_advances.len < output.len) return error.InvalidResult;
        const step = self.runFn(self.context, input, final, output, source_advances);
        switch (step) {
            .progress => |progress| {
                if (progress.consumed > input.len or progress.produced > output.len or
                    progress.consumed == 0 or progress.produced == 0)
                {
                    return error.InvalidResult;
                }
                var mapped: usize = 0;
                for (source_advances[0..progress.produced]) |advance| {
                    if (advance > progress.consumed - mapped) return error.InvalidResult;
                    mapped += advance;
                }
                if (mapped != progress.consumed) return error.InvalidResult;
            },
            .malformed => |offset| if (offset > input.len) return error.InvalidResult,
            .need_input => if (final and input.len != 0) return error.InvalidResult,
            .need_output, .unsupported, .cancelled => {},
        }
        return step;
    }
};
