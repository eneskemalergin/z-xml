//! Adapts XML byte sources to UTF-8 while preserving physical source locations.
//!
//! Reader handles UTF-8 and UTF-16 directly. Other encodings use a caller-owned `Transcoder`.
//! Calls are synchronous and borrow the context and all supplied buffers; the callback must not
//! retain them.
//!
//! Input windows are at most 255 bytes, so one encoded unit must fit within that bound. To retain
//! raw-byte locations, `source_advances` has one entry per produced UTF-8 byte and its entries must
//! sum to `consumed`. Empty final input followed by `need_input` completes the source; incomplete
//! final input must return `malformed`.

pub const SourceEncoding = enum {
    utf8,
    utf16_le,
    utf16_be,
    other,
};

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

pub const TranscoderError = error{InvalidResult};

pub const Transcoder = struct {
    context: ?*anyopaque,
    runFn: *const fn (
        context: ?*anyopaque,
        input: []const u8,
        final: bool,
        output: []u8,
        source_advances: []u8,
    ) TranscodeStep,

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
