//! Runs one compiled z-xml Reader profile as a streaming corpus adapter.
//!
//! The default command reads one file and writes the common event summary used by focused,
//! generated, and conformance checks. DTD-enabled profiles resolve companion sources relative to
//! that file.
//!
//! `--dtd-report` selects the DTD baseline protocol. It keeps the same public Reader and bounded
//! stream source while making external-resource policy explicit. Its result includes exact event,
//! source, diagnostic, and optional Reader-owned memory fields. Parser failures retain their
//! normal nonzero status after the result is written.

const std = @import("std");
const xml = @import("z_xml");
const check_options = @import("check_options");
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const INPUT_BUFFER_SIZE = 64 * 1024;

const ExternalMode = enum {
    forbid,
    skip,
    resolve,
    unavailable,
    failure,
};

const Options = struct {
    dtd_report: bool = false,
    report_memory: bool = false,
    external: ?ExternalMode = null,
    max_dtd_bytes: ?usize = null,
    max_dtd_expanded_bytes: ?usize = null,
    max_external_source_bytes: ?usize = null,
    path: []const u8 = "",
};

const Stats = struct {
    document_starts: u8 = 0,
    document_ends: u8 = 0,
    elements: u64 = 0,
    end_elements: u64 = 0,
    attributes: u64 = 0,
    text_bytes: u64 = 0,
    defaulted_attributes: u64 = 0,
    skipped_sources: u64 = 0,
    checksum: u64 = 14695981039346656037,
    semantic_match: bool = true,
    content: ?xml.DocumentContent = null,

    fn bytes(self: *Stats, value: []const u8) void {
        for (value) |byte| {
            self.checksum ^= byte;
            self.checksum *%= 1099511628211;
        }
    }

    fn marker(self: *Stats, value: u8) void {
        self.bytes(&.{value});
    }

    fn observe(self: *Stats, event: xml.Event) void {
        self.observePayload(event.data);
    }

    fn observePayload(self: *Stats, payload: anytype) void {
        switch (payload) {
            .document_start => self.document_starts +|= 1,
            .start_element => |start| {
                self.elements += 1;
                self.observeName(start.name);
                if (!check_options.namespaces and start.namespace_declarations.len != 0) {
                    self.semantic_match = false;
                }
                self.marker(1);
                self.bytes(start.name.raw);
                if (@hasField(@TypeOf(start), "namespace_declarations")) {
                    for (start.namespace_declarations) |declaration| {
                        self.marker(5);
                        self.bytes(declaration.prefix orelse "");
                        self.marker(6);
                        self.bytes(declaration.namespace_uri);
                    }
                }
                for (start.attributes) |attribute| {
                    self.attributes += 1;
                    if (!attribute.specified) self.defaulted_attributes += 1;
                    self.observeName(attribute.name);
                    self.marker(2);
                    self.bytes(attribute.name.raw);
                    self.marker(3);
                    self.bytes(attribute.value);
                }
            },
            .end_element => |end| {
                self.end_elements += 1;
                self.observeName(end.name);
                self.marker(4);
                self.bytes(end.name.raw);
            },
            .text => |text| {
                self.text_bytes += text.bytes.len;
                self.bytes(text.bytes);
            },
            .document_end => |result| {
                self.document_ends +|= 1;
                self.content = result.content;
                if (!check_options.validating and result.dtd_validity != .not_requested) {
                    self.semantic_match = false;
                }
            },
            .skipped_external_source => self.skipped_sources += 1,
            else => {},
        }
    }

    fn observeName(self: *Stats, name: xml.Name) void {
        if ((name.expanded != null) != check_options.namespaces) {
            self.semantic_match = false;
        }
    }

    fn complete(self: Stats) bool {
        return self.semantic_match and self.document_starts == 1 and
            self.document_ends == 1 and self.elements == self.end_elements;
    }
};

const ResolverStats = struct {
    calls: u64 = 0,
    resolved_sources: u64 = 0,
    closed_sources: u64 = 0,
    unavailable_results: u64 = 0,
    failure_results: u64 = 0,
    external_subset_sources: u64 = 0,
    parameter_entity_sources: u64 = 0,
    general_entity_sources: u64 = 0,
    source_bytes: u64 = 0,
};

const MeasuredResolver = struct {
    allocator: std.mem.Allocator,
    mode: ExternalMode,
    inner: ?xml.Resolver,
    stats: ResolverStats = .{},

    const WrappedSource = struct {
        owner: *MeasuredResolver,
        source: xml.ResolverSource,

        fn read(context: ?*anyopaque, output: []u8) xml.ResolverReadResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const result = self.source.read(output);
            if (result == .bytes) self.owner.stats.source_bytes += result.bytes;
            return result;
        }

        fn close(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const owner = self.owner;
            self.source.close();
            owner.stats.closed_sources += 1;
            owner.allocator.destroy(self);
        }
    };

    fn resolver(self: *MeasuredResolver) xml.Resolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(context: ?*anyopaque, request: xml.ResolverRequest) xml.ResolverResult {
        const self: *MeasuredResolver = @ptrCast(@alignCast(context.?));
        self.stats.calls += 1;
        switch (self.mode) {
            .unavailable => {
                self.stats.unavailable_results += 1;
                return .not_found;
            },
            .failure => {
                self.stats.failure_results += 1;
                return .io_failure;
            },
            .resolve => {},
            .forbid, .skip => unreachable,
        }
        const result = self.inner.?.resolve(request);
        if (result != .source) {
            switch (result) {
                .not_found => self.stats.unavailable_results += 1,
                .io_failure => self.stats.failure_results += 1,
                else => {},
            }
            return result;
        }
        const wrapped = self.allocator.create(WrappedSource) catch {
            result.source.close();
            return .resource_limit;
        };
        wrapped.* = .{ .owner = self, .source = result.source };
        self.stats.resolved_sources += 1;
        switch (request.kind) {
            .external_subset => self.stats.external_subset_sources += 1,
            .parameter_entity => self.stats.parameter_entity_sources += 1,
            .general_entity => self.stats.general_entity_sources += 1,
        }
        var source = result.source;
        source.context = wrapped;
        source.readFn = WrappedSource.read;
        source.closeFn = WrappedSource.close;
        return .{ .source = source };
    }
};

const Failure = struct {
    error_name: []const u8,
    diagnostic: ?[]const u8,
    source_id: ?u32,
    offset: ?u64,
    related_source_id: ?u32,
    related_offset: ?u64,
    inclusion_depth: usize,
};

const MemoryStats = struct {
    allocator_operations: u64,
    requested_bytes: u64,
    peak_live_bytes: usize,
    dtd_capacity: usize,
    document_capacity: usize,
    retained_capacity: usize,
    live_bytes_before_deinit: usize,
    live_bytes_after_deinit: usize,
    caller_root_storage_bytes: usize,
    caller_external_peak_bytes: usize,
    caller_external_live_after_deinit: usize,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-check: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = parseOptions(args) orelse {
        std.debug.print(
            "usage: z-xml-check [--dtd-report --external=forbid|skip|resolve|" ++
                "unavailable|failure] [--report-memory] " ++
                "[--max-dtd-bytes=N] [--max-dtd-expanded-bytes=N] " ++
                "[--max-external-source-bytes=N] FILE\n",
            .{},
        );
        return 64;
    };
    if (command.dtd_report) return runDtdReport(init, command);

    const file = try std.Io.Dir.cwd().openFile(init.io, command.path, .{});
    defer file.close(init.io);
    var root_dir: ?std.Io.Dir = null;
    defer if (root_dir) |dir| dir.close(init.io);
    var filesystem_resolver: if (check_options.dtd) xml.RootedFilesystemResolver else void = undefined;
    if (comptime check_options.dtd) {
        const directory = std.fs.path.dirname(command.path) orelse ".";
        root_dir = if (std.fs.path.isAbsolute(directory))
            try std.Io.Dir.openDirAbsolute(init.io, directory, .{})
        else
            try std.Io.Dir.cwd().openDir(init.io, directory, .{});
        filesystem_resolver = .init(init.gpa, init.io, root_dir.?);
    }
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var stats: Stats = .{};
    var options: xml.ReaderOptions = .{
        .namespaces = if (check_options.namespaces) .process else .raw,
        .dtd = if (check_options.validating)
            .{ .validate = .{} }
        else if (check_options.dtd)
            .process
        else
            .reject,
    };
    if (comptime check_options.dtd) {
        options.limits.max_dtd_comparison_work = 512 * 1024 * 1024;
        options.limits.max_dtd_entity_references = 8 * 1024 * 1024;
        options.limits.max_dtd_expanded_bytes = 256 * 1024 * 1024;
        options.limits.max_dtd_entity_replacement_bytes = 64 * 1024 * 1024;
        options.limits.max_dtd_expansion_ratio = 1000;
        options.external = .resolve;
        options.resolver = filesystem_resolver.resolver();
        options.document_base_id = std.fs.path.basename(command.path);
    }
    if (comptime check_options.validating) {
        options.limits.max_validation_ids = 8 * 1024 * 1024;
        options.limits.max_validation_idrefs = 8 * 1024 * 1024;
        options.limits.max_validation_identity_bytes = 256 * 1024 * 1024;
        options.limits.max_validation_comparison_work = 512 * 1024 * 1024;
    }
    var reader = try xml.Reader.init(
        init.gpa,
        .{ .stream = &file_reader.interface },
        options,
    );
    defer reader.deinit();
    while (true) {
        const event = reader.next() catch |err| {
            if (reader.diagnostic()) |diagnostic| printDiagnostic(diagnostic);
            if (statusForReadError(err)) |status| return status;
            return err;
        };
        if (event) |value| {
            if (comptime check_options.validating) switch (value.data) {
                .document_end => |result| if (result.dtd_validity != .valid) return 2,
                else => {},
            };
            stats.observe(value);
        } else break;
    }
    if (!stats.complete()) return error.SemanticMismatch;

    var output_buffer: [160]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    try output.print(
        "{{\"elements\":{d},\"attributes\":{d},\"text_bytes\":{d},\"checksum\":\"{x:0>16}\"}}\n",
        .{ stats.elements, stats.attributes, stats.text_bytes, stats.checksum },
    );
    try output.flush();
    return 0;
}

fn runDtdReport(init: std.process.Init, command: Options) !u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, command.path, .{});
    defer file.close(init.io);

    var reader_tracking: TrackingAllocator = .{ .child = init.gpa };
    var source_tracking: TrackingAllocator = .{ .child = init.gpa };
    var root_dir: ?std.Io.Dir = null;
    defer if (root_dir) |dir| dir.close(init.io);
    var filesystem_resolver: xml.RootedFilesystemResolver = undefined;
    const external = command.external.?;
    if (external == .resolve) {
        const directory = std.fs.path.dirname(command.path) orelse ".";
        root_dir = if (std.fs.path.isAbsolute(directory))
            try std.Io.Dir.openDirAbsolute(init.io, directory, .{})
        else
            try std.Io.Dir.cwd().openDir(init.io, directory, .{});
        filesystem_resolver = .init(source_tracking.allocator(), init.io, root_dir.?);
    }
    var measured_resolver: MeasuredResolver = .{
        .allocator = source_tracking.allocator(),
        .mode = external,
        .inner = if (external == .resolve) filesystem_resolver.resolver() else null,
    };
    var input_buffer: [INPUT_BUFFER_SIZE]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var reader_options: xml.ReaderOptions = .{
        .namespaces = if (check_options.namespaces) .process else .raw,
        .dtd = if (check_options.validating)
            .{ .validate = .{} }
        else if (check_options.dtd)
            .process
        else
            .reject,
        .external = switch (external) {
            .forbid => .forbid,
            .skip => .skip,
            .resolve, .unavailable, .failure => .resolve,
        },
    };
    if (comptime check_options.dtd) {
        reader_options.limits.max_dtd_comparison_work = 512 * 1024 * 1024;
        reader_options.limits.max_dtd_entity_references = 8 * 1024 * 1024;
        reader_options.limits.max_dtd_expanded_bytes = 256 * 1024 * 1024;
        reader_options.limits.max_dtd_entity_replacement_bytes = 64 * 1024 * 1024;
        reader_options.limits.max_dtd_expansion_ratio = 1000;
    }
    if (external == .resolve or external == .unavailable or external == .failure) {
        reader_options.resolver = measured_resolver.resolver();
        reader_options.document_base_id = std.fs.path.basename(command.path);
    }
    if (command.max_dtd_bytes) |value| reader_options.limits.max_dtd_bytes = value;
    if (command.max_dtd_expanded_bytes) |value| {
        reader_options.limits.max_dtd_expanded_bytes = value;
    }
    if (command.max_external_source_bytes) |value| {
        reader_options.limits.max_external_source_bytes = value;
    }

    var reader = try xml.Reader.init(
        reader_tracking.allocator(),
        .{ .stream = &file_reader.interface },
        reader_options,
    );
    var reader_live = true;
    defer if (reader_live) reader.deinit();
    var stats: Stats = .{};
    var failure: ?Failure = null;
    while (true) {
        const event = reader.next() catch |err| {
            const diagnostic = reader.diagnostic();
            failure = .{
                .error_name = @errorName(err),
                .diagnostic = if (diagnostic) |value| @tagName(value.code) else null,
                .source_id = if (diagnostic) |value| value.primary.source_id else null,
                .offset = if (diagnostic) |value| value.primary.byte_offset else null,
                .related_source_id = if (diagnostic) |value|
                    if (value.related) |related| related.source_id else null
                else
                    null,
                .related_offset = if (diagnostic) |value|
                    if (value.related) |related| related.byte_offset else null
                else
                    null,
                .inclusion_depth = if (diagnostic) |value| value.inclusion_trace.len else 0,
            };
            break;
        };
        if (event) |value| {
            stats.observe(value);
        } else break;
    }
    if (failure == null and !stats.complete()) return error.SemanticMismatch;

    const usage = reader.memoryUsage();
    const memory: MemoryStats = .{
        .allocator_operations = reader_tracking.allocs + reader_tracking.resizes +
            reader_tracking.remaps,
        .requested_bytes = reader_tracking.requested_bytes,
        .peak_live_bytes = reader_tracking.peak_live_bytes,
        .dtd_capacity = usage.dtd_capacity,
        .document_capacity = usage.retained_capacity -| usage.dtd_capacity,
        .retained_capacity = usage.retained_capacity,
        .live_bytes_before_deinit = reader_tracking.live_bytes,
        .live_bytes_after_deinit = 0,
        .caller_root_storage_bytes = INPUT_BUFFER_SIZE,
        .caller_external_peak_bytes = source_tracking.peak_live_bytes,
        .caller_external_live_after_deinit = 0,
    };
    reader.deinit();
    reader_live = false;
    var complete_memory = memory;
    complete_memory.live_bytes_after_deinit = reader_tracking.live_bytes;
    complete_memory.caller_external_live_after_deinit = source_tracking.live_bytes;
    try printDtdResult(
        init.io,
        stats,
        measured_resolver.stats,
        failure,
        if (command.report_memory) complete_memory else null,
    );
    return if (failure) |value| statusForErrorName(value.error_name) else 0;
}

fn parseOptions(args: []const []const u8) ?Options {
    var options: Options = .{};
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--dtd-report")) {
            if (options.dtd_report) return null;
            options.dtd_report = true;
        } else if (std.mem.eql(u8, argument, "--report-memory")) {
            if (options.report_memory) return null;
            options.report_memory = true;
        } else if (std.mem.startsWith(u8, argument, "--external=")) {
            if (options.external != null) return null;
            const value = argument["--external=".len..];
            options.external = std.meta.stringToEnum(ExternalMode, value) orelse return null;
        } else if (std.mem.startsWith(u8, argument, "--max-dtd-bytes=")) {
            if (options.max_dtd_bytes != null) return null;
            options.max_dtd_bytes = parsePositive(
                argument["--max-dtd-bytes=".len..],
            ) orelse return null;
        } else if (std.mem.startsWith(u8, argument, "--max-dtd-expanded-bytes=")) {
            if (options.max_dtd_expanded_bytes != null) return null;
            options.max_dtd_expanded_bytes = parsePositive(
                argument["--max-dtd-expanded-bytes=".len..],
            ) orelse return null;
        } else if (std.mem.startsWith(u8, argument, "--max-external-source-bytes=")) {
            if (options.max_external_source_bytes != null) return null;
            options.max_external_source_bytes = parsePositive(
                argument["--max-external-source-bytes=".len..],
            ) orelse return null;
        } else if (argument.len == 0 or argument[0] == '-' or options.path.len != 0) {
            return null;
        } else {
            options.path = argument;
        }
    }
    if (options.path.len == 0) return null;
    if (!options.dtd_report) {
        if (options.report_memory or options.external != null or options.max_dtd_bytes != null or
            options.max_dtd_expanded_bytes != null or options.max_external_source_bytes != null)
        {
            return null;
        }
        return options;
    }
    if (options.external == null) return null;
    if (!check_options.dtd and options.external.? != .forbid) return null;
    return options;
}

fn parsePositive(value: []const u8) ?usize {
    const result = std.fmt.parseInt(usize, value, 10) catch return null;
    return if (result == 0) null else result;
}

fn printDtdResult(
    io: std.Io,
    stats: Stats,
    resolver: ResolverStats,
    failure: ?Failure,
    memory: ?MemoryStats,
) !void {
    var output_buffer: [4096]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(io, &output_buffer);
    const output = &output_file.interface;
    try output.writeAll("{\"outcome\":");
    try printOptionalString(output, if (failure == null) "success" else "failure");
    try output.writeAll(",\"error\":");
    try printOptionalString(output, if (failure) |value| value.error_name else null);
    try output.writeAll(",\"diagnostic\":");
    try printOptionalString(output, if (failure) |value| value.diagnostic else null);
    try output.writeAll(",\"source_id\":");
    try printOptionalNumber(output, if (failure) |value| value.source_id else null);
    try output.writeAll(",\"offset\":");
    try printOptionalNumber(output, if (failure) |value| value.offset else null);
    try output.writeAll(",\"related_source_id\":");
    try printOptionalNumber(output, if (failure) |value| value.related_source_id else null);
    try output.writeAll(",\"related_offset\":");
    try printOptionalNumber(output, if (failure) |value| value.related_offset else null);
    try output.print(
        ",\"inclusion_depth\":{d},\"elements\":{d},\"attributes\":{d}," ++
            "\"defaulted_attributes\":{d},\"text_bytes\":{d}," ++
            "\"checksum\":\"{x:0>16}\",\"content\":",
        .{
            if (failure) |value| value.inclusion_depth else 0,
            stats.elements,
            stats.attributes,
            stats.defaulted_attributes,
            stats.text_bytes,
            stats.checksum,
        },
    );
    try printOptionalString(output, if (stats.content) |value| @tagName(value) else null);
    try output.print(
        ",\"resolver_calls\":{d},\"resolved_sources\":{d}," ++
            "\"closed_sources\":{d},\"unavailable_results\":{d}," ++
            "\"failure_results\":{d},\"external_subset_sources\":{d}," ++
            "\"parameter_entity_sources\":{d},\"general_entity_sources\":{d}," ++
            "\"skipped_sources\":{d},\"source_bytes\":{d}",
        .{
            resolver.calls,
            resolver.resolved_sources,
            resolver.closed_sources,
            resolver.unavailable_results,
            resolver.failure_results,
            resolver.external_subset_sources,
            resolver.parameter_entity_sources,
            resolver.general_entity_sources,
            stats.skipped_sources,
            resolver.source_bytes,
        },
    );
    if (memory) |value| {
        try output.print(
            ",\"allocator_operations\":{d},\"requested_bytes\":{d}," ++
                "\"peak_live_bytes\":{d},\"dtd_capacity\":{d}," ++
                "\"document_capacity\":{d},\"retained_capacity\":{d}," ++
                "\"live_bytes_before_deinit\":{d},\"live_bytes_after_deinit\":{d}," ++
                "\"caller_root_storage_bytes\":{d},\"caller_external_peak_bytes\":{d}," ++
                "\"caller_external_live_after_deinit\":{d}",
            .{
                value.allocator_operations,
                value.requested_bytes,
                value.peak_live_bytes,
                value.dtd_capacity,
                value.document_capacity,
                value.retained_capacity,
                value.live_bytes_before_deinit,
                value.live_bytes_after_deinit,
                value.caller_root_storage_bytes,
                value.caller_external_peak_bytes,
                value.caller_external_live_after_deinit,
            },
        );
    }
    try output.writeAll("}\n");
    try output.flush();
}

fn printOptionalString(output: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try output.print("\"{s}\"", .{text});
    } else {
        try output.writeAll("null");
    }
}

fn printOptionalNumber(output: *std.Io.Writer, value: anytype) !void {
    if (value) |number| {
        try output.print("{d}", .{number});
    } else {
        try output.writeAll("null");
    }
}

fn statusForErrorName(name: []const u8) u8 {
    inline for (.{
        error.InvalidXml,
        error.InvalidDtd,
        error.NotValid,
        error.InvalidEncoding,
        error.UnsupportedEncoding,
        error.UnsupportedVersion,
        error.DtdForbidden,
    }) |err| {
        if (std.mem.eql(u8, name, @errorName(err))) return 2;
    }
    inline for (.{ error.LimitExceeded, error.OutOfMemory }) |err| {
        if (std.mem.eql(u8, name, @errorName(err))) return 3;
    }
    return 1;
}

fn printDiagnostic(diagnostic: anytype) void {
    std.debug.print(
        "z-xml-check: {s} at source {d} byte {d}\n",
        .{ @tagName(diagnostic.code), diagnostic.primary.source_id, diagnostic.primary.byte_offset },
    );
}

fn statusForReadError(err: anyerror) ?u8 {
    return switch (err) {
        error.InvalidXml,
        error.InvalidDtd,
        error.NotValid,
        error.InvalidEncoding,
        error.UnsupportedEncoding,
        error.UnsupportedVersion,
        error.DtdForbidden,
        => 2,
        error.LimitExceeded, error.OutOfMemory => 3,
        else => null,
    };
}

// --- Tests ---

test "[unit] - [corpus adapter]: maps parser outcomes to contract statuses" {
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.InvalidXml));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.InvalidDtd));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.NotValid));
    try std.testing.expectEqual(@as(?u8, 3), statusForReadError(error.LimitExceeded));
    try std.testing.expectEqual(@as(?u8, 3), statusForReadError(error.OutOfMemory));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.InvalidEncoding));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.UnsupportedVersion));
    try std.testing.expectEqual(@as(?u8, 2), statusForReadError(error.DtdForbidden));
    try std.testing.expectEqual(@as(?u8, null), statusForReadError(error.UnsupportedFeature));
    try std.testing.expectEqual(@as(?u8, null), statusForReadError(error.ReadFailed));
}

test "[unit] - [corpus adapter]: requires one balanced document" {
    var stats: Stats = .{};
    try std.testing.expect(!stats.complete());
    stats.document_starts = 1;
    stats.document_ends = 1;
    stats.elements = 2;
    stats.end_elements = 2;
    try std.testing.expect(stats.complete());
    stats.semantic_match = false;
    try std.testing.expect(!stats.complete());
}

test "[unit] - [corpus adapter options]: keeps legacy and DTD commands distinct" {
    const legacy = parseOptions(&.{ "z-xml-check", "input.xml" }).?;
    try std.testing.expect(!legacy.dtd_report);
    try std.testing.expectEqualStrings("input.xml", legacy.path);

    const dtd = parseOptions(&.{
        "z-xml-check",
        "--dtd-report",
        "--external=forbid",
        "--report-memory",
        "--max-dtd-bytes=7",
        "input.xml",
    }).?;
    try std.testing.expect(dtd.dtd_report);
    try std.testing.expect(dtd.report_memory);
    try std.testing.expectEqual(ExternalMode.forbid, dtd.external.?);
    try std.testing.expectEqual(@as(?usize, 7), dtd.max_dtd_bytes);
    try std.testing.expect(parseOptions(&.{ "z-xml-check", "--report-memory", "x" }) == null);
    try std.testing.expect(parseOptions(&.{ "z-xml-check", "--dtd-report", "x" }) == null);
    try std.testing.expect(parseOptions(&.{
        "z-xml-check",
        "--dtd-report",
        "--external=forbid",
        "--max-dtd-bytes=0",
        "x",
    }) == null);
}
