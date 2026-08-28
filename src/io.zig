//! Adapts configured Readers to final slices, buffered `std.Io.Reader` sources, and synchronous
//! event callbacks.
//!
//! Adapters own parser state and borrow their input. A slice remains borrowed until `.done`, an
//! error, or `deinit`; `IoReader` borrows the input reader until `deinit` and does not deinitialize
//! it. Reported memory covers parser-owned storage only.
//!
//! Drain callbacks run synchronously. Returning `.cancel` stops with `error.Cancelled`.

const std = @import("std");
const reader = @import("reader.zig");

pub const DrainControl = enum {
    continue_parsing,
    cancel,
};

pub fn SliceReader(comptime config: reader.Config) type {
    return struct {
        const Self = @This();

        parser: reader.Reader(config),

        pub fn init(
            allocator: std.mem.Allocator,
            options: reader.Options(config),
            input: []const u8,
        ) (reader.InitError || reader.FeedError)!Self {
            var parser = try reader.Reader(config).init(allocator, options);
            errdefer parser.deinit();
            try parser.feed(input, true);
            return .{ .parser = parser };
        }

        pub fn deinit(self: *Self) void {
            self.parser.deinit();
        }

        pub fn next(self: *Self) reader.ReadError!reader.Step(config) {
            return self.parser.next();
        }

        pub fn diagnostic(self: *const Self) ?reader.Diagnostic(config) {
            return self.parser.diagnostic();
        }

        pub fn memoryUsage(self: *const Self) reader.MemoryUsage {
            return self.parser.memoryUsage();
        }
    };
}

pub fn IoReader(comptime config: reader.Config) type {
    return struct {
        const Self = @This();

        parser: reader.Reader(config),
        input: *std.Io.Reader,
        pending_toss: usize = 0,
        source_finished: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            options: reader.Options(config),
            input: *std.Io.Reader,
        ) reader.InitError!Self {
            return .{
                .parser = try reader.Reader(config).init(allocator, options),
                .input = input,
            };
        }

        pub fn deinit(self: *Self) void {
            self.parser.deinit();
        }

        pub fn next(self: *Self) reader.ReadError!reader.Step(config) {
            while (true) {
                if (self.parser.lifecycle == .ready or self.parser.lifecycle == .needs_input) {
                    try self.refill();
                }

                switch (try self.parser.next()) {
                    .need_input => continue,
                    .event => |event| return .{ .event = event },
                    .done => return .done,
                }
            }
        }

        pub fn diagnostic(self: *const Self) ?reader.Diagnostic(config) {
            return self.parser.diagnostic();
        }

        pub fn memoryUsage(self: *const Self) reader.MemoryUsage {
            return self.parser.memoryUsage();
        }

        fn refill(self: *Self) reader.ReadError!void {
            if (self.pending_toss > 0) {
                self.input.toss(self.pending_toss);
                self.pending_toss = 0;
            }

            if (self.source_finished) return error.InvalidState;
            const input = self.input.peekGreedy(1) catch |read_error| switch (read_error) {
                error.EndOfStream => {
                    self.source_finished = true;
                    self.parser.feed("", true) catch return error.InvalidState;
                    return;
                },
                error.ReadFailed => return reader.AdapterAccess(config).recordReadFailure(&self.parser),
            };
            self.parser.feed(input, false) catch return error.InvalidState;
            self.pending_toss = input.len;
        }
    };
}

pub fn drainSlice(
    comptime config: reader.Config,
    allocator: std.mem.Allocator,
    options: reader.Options(config),
    input: []const u8,
    context: anytype,
    comptime callback: fn (@TypeOf(context), reader.Event(config)) DrainControl,
) !void {
    var pull = try SliceReader(config).init(allocator, options, input);
    defer pull.deinit();
    try drainPull(config, &pull, context, callback);
}

pub fn drainIo(
    comptime config: reader.Config,
    allocator: std.mem.Allocator,
    options: reader.Options(config),
    input: *std.Io.Reader,
    context: anytype,
    comptime callback: fn (@TypeOf(context), reader.Event(config)) DrainControl,
) !void {
    var pull = try IoReader(config).init(allocator, options, input);
    defer pull.deinit();
    try drainPull(config, &pull, context, callback);
}

fn drainPull(
    comptime config: reader.Config,
    pull: anytype,
    context: anytype,
    comptime callback: fn (@TypeOf(context), reader.Event(config)) DrainControl,
) reader.ReadError!void {
    while (true) {
        switch (try pull.next()) {
            .event => |event| switch (callback(context, event)) {
                .continue_parsing => {},
                .cancel => return error.Cancelled,
            },
            .need_input => return error.InvalidState,
            .done => return,
        }
    }
}
