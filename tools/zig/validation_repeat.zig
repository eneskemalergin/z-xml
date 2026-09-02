//! Measures repeated validation with fresh or reusable external DTD state.
//!
//! Both builds keep one public Reader and stream each document through a 64 KiB caller buffer.
//! The fresh build resolves and parses the external subset after every reset. The reused build
//! compiles one immutable ExternalSubset before Reader construction and borrows it for every
//! document. Exact event and finding summaries must remain stable across every repetition.
//!
//! Optional reports separate subset setup from Reader initialization and document phases. Memory
//! fields keep immutable subset storage, Reader grammar copies, per-document identity state,
//! resolver storage, retained capacity, explicit release, and deinitialization distinct.

const std = @import("std");
const xml = @import("z_xml");
const repeat_options = @import("repeat_options");
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const input_buffer_size = 64 * 1024;

const Options = struct {
    dtd_name: []const u8 = "",
    iterations: usize = 1,
    next_name: ?[]const u8 = null,
    next_iterations: usize = 0,
    report_memory: bool = false,
    report_timing: bool = false,
    release_memory: bool = false,
    path: []const u8 = "",
};

const Stats = struct {
    document_starts: u8 = 0,
    document_ends: u8 = 0,
    elements: u64 = 0,
    end_elements: u64 = 0,
    attributes: u64 = 0,
    defaulted_attributes: u64 = 0,
    text_bytes: u64 = 0,
    checksum: u64 = 14695981039346656037,
    content: ?xml.DocumentContent = null,
    validity: ?xml.DtdValidity = null,

    fn bytes(self: *Stats, value: []const u8) void {
        for (value) |byte| {
            self.checksum ^= byte;
            self.checksum *%= 1099511628211;
        }
    }

    fn observe(self: *Stats, event: xml.Event) void {
        switch (event.data) {
            .document_start => self.document_starts +|= 1,
            .start_element => |start| {
                self.elements += 1;
                self.bytes(&.{1});
                self.bytes(start.name.raw);
                for (start.attributes) |attribute| {
                    self.attributes += 1;
                    if (!attribute.specified) self.defaulted_attributes += 1;
                    self.bytes(&.{2});
                    self.bytes(attribute.name.raw);
                    self.bytes(&.{3});
                    self.bytes(attribute.value);
                }
            },
            .end_element => |end| {
                self.end_elements += 1;
                self.bytes(&.{4});
                self.bytes(end.name.raw);
            },
            .text => |text| {
                self.text_bytes += text.bytes.len;
                self.bytes(text.bytes);
            },
            .document_end => |result| {
                self.document_ends +|= 1;
                self.content = result.content;
                self.validity = result.dtd_validity;
            },
            else => {},
        }
    }

    fn complete(self: Stats) bool {
        return self.document_starts == 1 and self.document_ends == 1 and
            self.elements == self.end_elements and self.content != null and
            self.validity != null;
    }
};

const FindingStats = struct {
    count: u64 = 0,
    checksum: u64 = 14695981039346656037,
    first: ?xml.DiagnosticCode = null,
    last: ?xml.DiagnosticCode = null,
    first_primary: ?xml.Location = null,
    last_primary: ?xml.Location = null,

    fn sink(self: *FindingStats) xml.dtd.FindingSink {
        return .{ .context = self, .report_fn = report };
    }

    fn report(context: ?*anyopaque, finding: xml.dtd.Finding) xml.dtd.FindingAction {
        const self: *FindingStats = @ptrCast(@alignCast(context.?));
        const code = @tagName(finding.code);
        self.count += 1;
        if (self.first == null) {
            self.first = finding.code;
            self.first_primary = finding.primary;
        }
        self.last = finding.code;
        self.last_primary = finding.primary;
        for (code) |byte| self.hashByte(byte);
        self.hashByte(0);
        self.hashLocation(finding.primary);
        if (finding.related) |related| {
            self.hashByte(1);
            self.hashLocation(related);
        } else {
            self.hashByte(0);
        }
        self.hashNumber(finding.inclusion_trace.len);
        for (finding.inclusion_trace) |location| self.hashLocation(location);
        return .continue_validation;
    }

    fn hashLocation(self: *FindingStats, location: xml.Location) void {
        self.hashNumber(location.source_id);
        self.hashNumber(location.byte_offset);
    }

    fn hashNumber(self: *FindingStats, value: u64) void {
        var remaining = value;
        for (0..8) |_| {
            self.hashByte(@truncate(remaining));
            remaining >>= 8;
        }
    }

    fn hashByte(self: *FindingStats, byte: u8) void {
        self.checksum ^= byte;
        self.checksum *%= 1099511628211;
    }
};

const DocumentResult = struct {
    stats: Stats,
    findings: FindingStats,
    id_count: usize,
    idref_count: usize,
};

const ResolverStats = struct {
    calls: u64 = 0,
    resolved_sources: u64 = 0,
    closed_sources: u64 = 0,
    external_subset_sources: u64 = 0,
    source_bytes: u64 = 0,
};

const MeasuredResolver = struct {
    allocator: std.mem.Allocator,
    inner: xml.Resolver,
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
        const result = self.inner.resolve(request);
        if (result != .source) return result;
        const wrapped = self.allocator.create(WrappedSource) catch {
            result.source.close();
            return .resource_limit;
        };
        wrapped.* = .{ .owner = self, .source = result.source };
        self.stats.resolved_sources += 1;
        if (request.kind == .external_subset) self.stats.external_subset_sources += 1;
        var source = result.source;
        source.context = wrapped;
        source.readFn = WrappedSource.read;
        source.closeFn = WrappedSource.close;
        return .{ .source = source };
    }
};

const SubsetUsage = struct {
    declaration_capacity: usize = 0,
    validation_capacity: usize = 0,
    identifier_bytes: usize = 0,
    source_capacity: usize = 0,
};

const TimingStats = struct {
    dtd_read_ns: i96 = 0,
    subset_compile_ns: i96 = 0,
    reader_init_ns: i96 = 0,
    first_document_ns: i96 = 0,
    primary_warm_ns: i96 = 0,
    next_documents_ns: i96 = 0,
    release_ns: i96 = 0,
};

const MemoryStats = struct {
    dtd_input_bytes: u64,
    caller_input_storage_bytes: usize,
    subset_declaration_capacity: usize,
    subset_validation_capacity: usize,
    subset_identifier_bytes: usize,
    subset_source_capacity: usize,
    subset_retained_bytes: usize,
    subset_allocator_operations: u64,
    subset_requested_bytes: u64,
    subset_peak_live_bytes: usize,
    subset_live_after_compile: usize,
    subset_live_after_documents: usize,
    subset_live_after_deinit: usize,
    reader_init_allocator_operations: u64,
    first_document_allocator_operations: u64,
    primary_warm_allocator_operations: u64,
    next_allocator_operations: u64,
    release_allocator_operations: u64,
    reader_allocator_allocs: u64,
    reader_allocator_resizes: u64,
    reader_allocator_remaps: u64,
    reader_requested_bytes: u64,
    reader_peak_live_bytes: usize,
    primary_grammar_capacity: usize,
    primary_identity_capacity: usize,
    primary_identity_bytes: usize,
    primary_document_capacity: usize,
    primary_retained_capacity: usize,
    final_grammar_capacity: usize,
    final_identity_capacity: usize,
    final_identity_bytes: usize,
    final_document_capacity: usize,
    final_retained_capacity: usize,
    reader_live_before_release: usize,
    retained_capacity_after_release: usize,
    reader_live_after_release: usize,
    reader_live_after_deinit: usize,
    resolver_allocator_operations: u64,
    resolver_requested_bytes: u64,
    resolver_peak_live_bytes: usize,
    resolver_live_after_documents: usize,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("z-xml-validation-repeat: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args) orelse {
        std.debug.print(
            "usage: z-xml-validation-repeat --dtd=FILE [--iterations=N] " ++
                "[--next-file=FILE --next-iterations=N] [--report-memory] " ++
                "[--report-timing] [--release-memory] XML\n",
            .{},
        );
        return 64;
    };

    const directory = std.fs.path.dirname(options.path) orelse ".";
    const dtd_path = try std.fs.path.join(
        init.arena.allocator(),
        &.{ directory, options.dtd_name },
    );
    const next_path = if (options.next_name) |name|
        try std.fs.path.join(init.arena.allocator(), &.{ directory, name })
    else
        null;

    const primary_file = try std.Io.Dir.cwd().openFile(init.io, options.path, .{});
    defer primary_file.close(init.io);
    const primary_bytes = (try primary_file.stat(init.io)).size;
    const next_file: ?std.Io.File = if (next_path) |path|
        try std.Io.Dir.cwd().openFile(init.io, path, .{})
    else
        null;
    defer if (next_file) |file| file.close(init.io);
    const next_bytes = if (next_file) |file| (try file.stat(init.io)).size else 0;
    const dtd_file = try std.Io.Dir.cwd().openFile(init.io, dtd_path, .{});
    defer dtd_file.close(init.io);
    const dtd_input_bytes = (try dtd_file.stat(init.io)).size;

    var root_dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(init.io, directory, .{})
    else
        try std.Io.Dir.cwd().openDir(init.io, directory, .{});
    defer root_dir.close(init.io);

    var reader_tracking: TrackingAllocator = .{ .child = init.gpa };
    var subset_tracking: TrackingAllocator = .{ .child = init.gpa };
    var resolver_tracking: TrackingAllocator = .{ .child = init.gpa };
    var filesystem_resolver = xml.RootedFilesystemResolver.init(
        resolver_tracking.allocator(),
        init.io,
        root_dir,
    );
    var measured_resolver: MeasuredResolver = .{
        .allocator = resolver_tracking.allocator(),
        .inner = filesystem_resolver.resolver(),
    };

    var timing: TimingStats = .{};
    var subset_usage: SubsetUsage = .{};
    var subset: ?xml.dtd.ExternalSubset = null;
    defer if (subset) |*value| value.deinit();
    if (comptime repeat_options.reuse) {
        const read_start = if (options.report_timing)
            std.Io.Clock.awake.now(init.io)
        else
            undefined;
        const declaration_bytes = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            dtd_path,
            init.gpa,
            .limited(64 * 1024 * 1024),
        );
        defer init.gpa.free(declaration_bytes);
        if (options.report_timing) {
            timing.dtd_read_ns = read_start.durationTo(
                std.Io.Clock.awake.now(init.io),
            ).nanoseconds;
        }
        const compile_start = if (options.report_timing)
            std.Io.Clock.awake.now(init.io)
        else
            undefined;
        var subset_options: xml.dtd.ExternalSubsetOptions = .{
            .base_id = options.dtd_name,
            .source_id = 1,
        };
        subset_options.dtd_limits.max_comparison_work = 512 * 1024 * 1024;
        subset_options.validation_limits.max_comparison_work = 512 * 1024 * 1024;
        subset = try xml.dtd.ExternalSubset.compileDecoded(
            subset_tracking.allocator(),
            options.dtd_name,
            declaration_bytes,
            subset_options,
        );
        if (options.report_timing) {
            timing.subset_compile_ns = compile_start.durationTo(
                std.Io.Clock.awake.now(init.io),
            ).nanoseconds;
        }
        const usage = subset.?.memoryUsage();
        subset_usage = .{
            .declaration_capacity = usage.declaration_capacity,
            .validation_capacity = usage.validation_capacity,
            .identifier_bytes = usage.identifier_bytes,
            .source_capacity = usage.source_capacity,
        };
    }
    const subset_live_after_compile = subset_tracking.live_bytes;

    var primary_buffer: [input_buffer_size]u8 = undefined;
    var next_buffer: [input_buffer_size]u8 = undefined;
    var primary_reader = primary_file.reader(init.io, &primary_buffer);
    var next_reader = if (next_file) |file| file.reader(init.io, &next_buffer) else null;
    var findings: FindingStats = .{};
    var reader_options = makeReaderOptions(
        &findings,
        std.fs.path.basename(options.path),
        &measured_resolver,
        if (subset) |*value| value else null,
    );
    const reader_init_start = if (options.report_timing)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    var reader = try xml.Reader.init(
        reader_tracking.allocator(),
        .{ .stream = &primary_reader.interface },
        reader_options,
    );
    if (options.report_timing) {
        timing.reader_init_ns = reader_init_start.durationTo(
            std.Io.Clock.awake.now(init.io),
        ).nanoseconds;
    }
    var reader_live = true;
    defer if (reader_live) reader.deinit();

    const after_reader_init_operations = reader_tracking.operations();
    const first_start = if (options.report_timing)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    const primary_result = try drain(&reader, &findings);
    if (options.report_timing) {
        timing.first_document_ns = first_start.durationTo(
            std.Io.Clock.awake.now(init.io),
        ).nanoseconds;
    }
    const after_first_operations = reader_tracking.operations();

    const warm_start = if (options.report_timing and options.iterations > 1)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    for (1..options.iterations) |_| {
        try primary_reader.seekTo(0);
        findings = .{};
        try reader.reset(
            .{ .stream = &primary_reader.interface },
            reader_options,
            .retain_capacity,
        );
        const repeated = try drain(&reader, &findings);
        if (!std.meta.eql(primary_result, repeated)) return error.IterationMismatch;
    }
    if (options.report_timing and options.iterations > 1) {
        timing.primary_warm_ns = warm_start.durationTo(
            std.Io.Clock.awake.now(init.io),
        ).nanoseconds;
    }
    const after_primary_operations = reader_tracking.operations();
    const primary_usage = reader.memoryUsage();

    var next_result: ?DocumentResult = null;
    const next_start = if (options.report_timing and next_reader != null)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    if (next_reader) |*source| {
        if (!repeat_options.reuse) {
            reader_options.document_base_id = std.fs.path.basename(next_path.?);
        }
        for (0..options.next_iterations) |iteration| {
            if (iteration > 0) try source.seekTo(0);
            findings = .{};
            try reader.reset(
                .{ .stream = &source.interface },
                reader_options,
                .retain_capacity,
            );
            const repeated = try drain(&reader, &findings);
            if (next_result) |expected| {
                if (!std.meta.eql(expected, repeated)) return error.IterationMismatch;
            } else {
                next_result = repeated;
            }
        }
    }
    if (options.report_timing and next_reader != null) {
        timing.next_documents_ns = next_start.durationTo(
            std.Io.Clock.awake.now(init.io),
        ).nanoseconds;
    }
    const after_next_operations = reader_tracking.operations();
    const final_usage = reader.memoryUsage();
    const reader_live_before_release = reader_tracking.live_bytes;
    const subset_live_after_documents = subset_tracking.live_bytes;
    const resolver_live_after_documents = resolver_tracking.live_bytes;

    const release_start = if (options.report_timing and options.release_memory)
        std.Io.Clock.awake.now(init.io)
    else
        undefined;
    if (options.release_memory) {
        try reader.reset(
            if (next_reader) |*source|
                .{ .stream = &source.interface }
            else
                .{ .stream = &primary_reader.interface },
            reader_options,
            .release_memory,
        );
    }
    if (options.report_timing and options.release_memory) {
        timing.release_ns = release_start.durationTo(
            std.Io.Clock.awake.now(init.io),
        ).nanoseconds;
    }
    const after_release_operations = reader_tracking.operations();
    const released_usage = reader.memoryUsage();
    const reader_live_after_release = reader_tracking.live_bytes;
    reader.deinit();
    reader_live = false;
    const reader_live_after_deinit = reader_tracking.live_bytes;

    if (subset) |*value| value.deinit();
    subset = null;
    const subset_live_after_deinit = subset_tracking.live_bytes;

    const memory: MemoryStats = .{
        .dtd_input_bytes = dtd_input_bytes,
        .caller_input_storage_bytes = @as(usize, input_buffer_size) +
            if (next_reader != null) @as(usize, input_buffer_size) else 0,
        .subset_declaration_capacity = subset_usage.declaration_capacity,
        .subset_validation_capacity = subset_usage.validation_capacity,
        .subset_identifier_bytes = subset_usage.identifier_bytes,
        .subset_source_capacity = subset_usage.source_capacity,
        .subset_retained_bytes = subset_usage.declaration_capacity +|
            subset_usage.validation_capacity +| subset_usage.identifier_bytes +|
            subset_usage.source_capacity,
        .subset_allocator_operations = subset_tracking.operations(),
        .subset_requested_bytes = subset_tracking.requested_bytes,
        .subset_peak_live_bytes = subset_tracking.peak_live_bytes,
        .subset_live_after_compile = subset_live_after_compile,
        .subset_live_after_documents = subset_live_after_documents,
        .subset_live_after_deinit = subset_live_after_deinit,
        .reader_init_allocator_operations = after_reader_init_operations,
        .first_document_allocator_operations = after_first_operations -
            after_reader_init_operations,
        .primary_warm_allocator_operations = after_primary_operations -
            after_first_operations,
        .next_allocator_operations = after_next_operations - after_primary_operations,
        .release_allocator_operations = after_release_operations - after_next_operations,
        .reader_allocator_allocs = reader_tracking.allocs,
        .reader_allocator_resizes = reader_tracking.resizes,
        .reader_allocator_remaps = reader_tracking.remaps,
        .reader_requested_bytes = reader_tracking.requested_bytes,
        .reader_peak_live_bytes = reader_tracking.peak_live_bytes,
        .primary_grammar_capacity = grammarCapacity(primary_usage),
        .primary_identity_capacity = primary_usage.identity_capacity,
        .primary_identity_bytes = primary_usage.identity_bytes,
        .primary_document_capacity = documentCapacity(primary_usage),
        .primary_retained_capacity = primary_usage.retained_capacity,
        .final_grammar_capacity = grammarCapacity(final_usage),
        .final_identity_capacity = final_usage.identity_capacity,
        .final_identity_bytes = final_usage.identity_bytes,
        .final_document_capacity = documentCapacity(final_usage),
        .final_retained_capacity = final_usage.retained_capacity,
        .reader_live_before_release = reader_live_before_release,
        .retained_capacity_after_release = released_usage.retained_capacity,
        .reader_live_after_release = reader_live_after_release,
        .reader_live_after_deinit = reader_live_after_deinit,
        .resolver_allocator_operations = resolver_tracking.operations(),
        .resolver_requested_bytes = resolver_tracking.requested_bytes,
        .resolver_peak_live_bytes = resolver_tracking.peak_live_bytes,
        .resolver_live_after_documents = resolver_live_after_documents,
    };

    try printResult(
        init.io,
        options,
        primary_bytes,
        next_bytes,
        primary_result,
        next_result,
        measured_resolver.stats,
        memory,
        timing,
    );
    return 0;
}

fn makeReaderOptions(
    findings: *FindingStats,
    base_id: []const u8,
    resolver: *MeasuredResolver,
    subset: ?*const xml.dtd.ExternalSubset,
) xml.ReaderOptions {
    var options: xml.ReaderOptions = .{
        .namespaces = .process,
        .dtd = .{ .validate = .{ .finding_sink = findings.sink() } },
    };
    options.limits.max_dtd_comparison_work = 512 * 1024 * 1024;
    options.limits.max_validation_ids = 8 * 1024 * 1024;
    options.limits.max_validation_idrefs = 8 * 1024 * 1024;
    options.limits.max_validation_identity_bytes = 256 * 1024 * 1024;
    options.limits.max_validation_comparison_work = 512 * 1024 * 1024;
    options.limits.max_retained_bytes = 512 * 1024 * 1024;
    if (subset) |value| {
        options.dtd.validate.external_subset = value;
    } else {
        options.external = .resolve;
        options.resolver = resolver.resolver();
        options.document_base_id = base_id;
    }
    return options;
}

fn drain(reader: *xml.Reader, findings: *FindingStats) !DocumentResult {
    var stats: Stats = .{};
    while (try reader.next()) |event| stats.observe(event);
    if (!stats.complete()) return error.SemanticMismatch;
    const usage = reader.memoryUsage();
    return .{
        .stats = stats,
        .findings = findings.*,
        .id_count = usage.id_count,
        .idref_count = usage.idref_count,
    };
}

fn grammarCapacity(usage: xml.MemoryUsage) usize {
    return usage.dtd_capacity +| usage.content_model_capacity;
}

fn documentCapacity(usage: xml.MemoryUsage) usize {
    return usage.retained_capacity -| grammarCapacity(usage);
}

fn parseOptions(args: []const []const u8) ?Options {
    var options: Options = .{};
    for (args[1..]) |argument| {
        if (std.mem.startsWith(u8, argument, "--dtd=")) {
            const name = argument["--dtd=".len..];
            if (!validRelativeName(name) or options.dtd_name.len != 0) return null;
            options.dtd_name = name;
        } else if (std.mem.startsWith(u8, argument, "--iterations=")) {
            options.iterations = std.fmt.parseInt(
                usize,
                argument["--iterations=".len..],
                10,
            ) catch return null;
            if (options.iterations == 0) return null;
        } else if (std.mem.startsWith(u8, argument, "--next-file=")) {
            const name = argument["--next-file=".len..];
            if (!validRelativeName(name) or options.next_name != null) return null;
            options.next_name = name;
        } else if (std.mem.startsWith(u8, argument, "--next-iterations=")) {
            options.next_iterations = std.fmt.parseInt(
                usize,
                argument["--next-iterations=".len..],
                10,
            ) catch return null;
            if (options.next_iterations == 0) return null;
        } else if (std.mem.eql(u8, argument, "--report-memory")) {
            options.report_memory = true;
        } else if (std.mem.eql(u8, argument, "--report-timing")) {
            options.report_timing = true;
        } else if (std.mem.eql(u8, argument, "--release-memory")) {
            options.release_memory = true;
        } else if (argument.len == 0 or argument[0] == '-' or options.path.len != 0) {
            return null;
        } else {
            options.path = argument;
        }
    }
    if ((options.next_name == null) != (options.next_iterations == 0)) return null;
    if (options.release_memory and !options.report_memory) return null;
    return if (options.dtd_name.len == 0 or options.path.len == 0) null else options;
}

fn validRelativeName(value: []const u8) bool {
    return value.len != 0 and std.mem.eql(u8, value, std.fs.path.basename(value)) and
        !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

fn printResult(
    io: std.Io,
    options: Options,
    input_bytes: u64,
    next_input_bytes: u64,
    primary: DocumentResult,
    next: ?DocumentResult,
    resolver: ResolverStats,
    memory: MemoryStats,
    timing: TimingStats,
) !void {
    var output_buffer: [8192]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(io, &output_buffer);
    const output = &output_file.interface;
    try output.print(
        "{{\"mode\":\"{s}\",\"iterations\":{d},\"input_bytes\":{d}," ++
            "\"elements\":{d},\"attributes\":{d},\"defaulted_attributes\":{d}," ++
            "\"text_bytes\":{d},\"event_checksum\":\"{x:0>16}\",\"content\":",
        .{
            if (repeat_options.reuse) "reused" else "fresh",
            options.iterations,
            input_bytes,
            primary.stats.elements,
            primary.stats.attributes,
            primary.stats.defaulted_attributes,
            primary.stats.text_bytes,
            primary.stats.checksum,
        },
    );
    try printOptionalString(
        output,
        if (primary.stats.content) |value| @tagName(value) else null,
    );
    try output.writeAll(",\"validity\":");
    try printOptionalString(
        output,
        if (primary.stats.validity) |value| @tagName(value) else null,
    );
    try printFindingResult(output, "", primary);
    if (next) |result| {
        try output.print(
            ",\"next_iterations\":{d},\"next_input_bytes\":{d}," ++
                "\"next_elements\":{d},\"next_attributes\":{d}," ++
                "\"next_defaulted_attributes\":{d},\"next_text_bytes\":{d}," ++
                "\"next_event_checksum\":\"{x:0>16}\",\"next_content\":",
            .{
                options.next_iterations,
                next_input_bytes,
                result.stats.elements,
                result.stats.attributes,
                result.stats.defaulted_attributes,
                result.stats.text_bytes,
                result.stats.checksum,
            },
        );
        try printOptionalString(
            output,
            if (result.stats.content) |value| @tagName(value) else null,
        );
        try output.writeAll(",\"next_validity\":");
        try printOptionalString(
            output,
            if (result.stats.validity) |value| @tagName(value) else null,
        );
        try printFindingResult(output, "next_", result);
    }
    try output.print(
        ",\"resolver_calls\":{d},\"resolved_sources\":{d}," ++
            "\"closed_sources\":{d},\"external_subset_sources\":{d}," ++
            "\"source_bytes\":{d}",
        .{
            resolver.calls,
            resolver.resolved_sources,
            resolver.closed_sources,
            resolver.external_subset_sources,
            resolver.source_bytes,
        },
    );
    if (options.report_memory) try printMemory(output, memory, options.release_memory);
    if (options.report_timing) {
        try output.print(
            ",\"dtd_read_ns\":{d},\"subset_compile_ns\":{d}," ++
                "\"reader_init_ns\":{d},\"first_document_ns\":{d}," ++
                "\"primary_warm_ns\":{d},\"next_documents_ns\":{d}," ++
                "\"release_ns\":{d}",
            .{
                timing.dtd_read_ns,
                timing.subset_compile_ns,
                timing.reader_init_ns,
                timing.first_document_ns,
                timing.primary_warm_ns,
                timing.next_documents_ns,
                timing.release_ns,
            },
        );
    }
    try output.writeAll("}\n");
    try output.flush();
}

fn printFindingResult(
    output: *std.Io.Writer,
    comptime prefix: []const u8,
    result: DocumentResult,
) !void {
    try output.print(
        ",\"{s}findings\":{d},\"{s}findings_checksum\":\"{x:0>16}\"," ++
            "\"{s}id_count\":{d},\"{s}idref_count\":{d},\"{s}first_finding\":",
        .{
            prefix,
            result.findings.count,
            prefix,
            result.findings.checksum,
            prefix,
            result.id_count,
            prefix,
            result.idref_count,
            prefix,
        },
    );
    try printOptionalString(
        output,
        if (result.findings.first) |value| @tagName(value) else null,
    );
    try output.print(",\"{s}first_finding_source_id\":", .{prefix});
    try printOptionalNumber(
        output,
        if (result.findings.first_primary) |value| value.source_id else null,
    );
    try output.print(",\"{s}first_finding_offset\":", .{prefix});
    try printOptionalNumber(
        output,
        if (result.findings.first_primary) |value| value.byte_offset else null,
    );
    try output.print(",\"{s}last_finding\":", .{prefix});
    try printOptionalString(
        output,
        if (result.findings.last) |value| @tagName(value) else null,
    );
    try output.print(",\"{s}last_finding_source_id\":", .{prefix});
    try printOptionalNumber(
        output,
        if (result.findings.last_primary) |value| value.source_id else null,
    );
    try output.print(",\"{s}last_finding_offset\":", .{prefix});
    try printOptionalNumber(
        output,
        if (result.findings.last_primary) |value| value.byte_offset else null,
    );
}

fn printMemory(output: *std.Io.Writer, value: MemoryStats, released: bool) !void {
    try output.print(
        ",\"dtd_input_bytes\":{d},\"caller_input_storage_bytes\":{d}," ++
            "\"subset_declaration_capacity\":{d}," ++
            "\"subset_validation_capacity\":{d}," ++
            "\"subset_identifier_bytes\":{d},\"subset_source_capacity\":{d}," ++
            "\"subset_retained_bytes\":{d},\"subset_allocator_operations\":{d}," ++
            "\"subset_requested_bytes\":{d},\"subset_peak_live_bytes\":{d}," ++
            "\"subset_live_after_compile\":{d}," ++
            "\"subset_live_after_documents\":{d}," ++
            "\"subset_live_after_deinit\":{d}," ++
            "\"reader_init_allocator_operations\":{d}," ++
            "\"first_document_allocator_operations\":{d}," ++
            "\"primary_warm_allocator_operations\":{d}," ++
            "\"next_allocator_operations\":{d}," ++
            "\"release_allocator_operations\":{d}," ++
            "\"reader_allocator_allocs\":{d},\"reader_allocator_resizes\":{d}," ++
            "\"reader_allocator_remaps\":{d},\"reader_requested_bytes\":{d}," ++
            "\"reader_peak_live_bytes\":{d}",
        .{
            value.dtd_input_bytes,
            value.caller_input_storage_bytes,
            value.subset_declaration_capacity,
            value.subset_validation_capacity,
            value.subset_identifier_bytes,
            value.subset_source_capacity,
            value.subset_retained_bytes,
            value.subset_allocator_operations,
            value.subset_requested_bytes,
            value.subset_peak_live_bytes,
            value.subset_live_after_compile,
            value.subset_live_after_documents,
            value.subset_live_after_deinit,
            value.reader_init_allocator_operations,
            value.first_document_allocator_operations,
            value.primary_warm_allocator_operations,
            value.next_allocator_operations,
            value.release_allocator_operations,
            value.reader_allocator_allocs,
            value.reader_allocator_resizes,
            value.reader_allocator_remaps,
            value.reader_requested_bytes,
            value.reader_peak_live_bytes,
        },
    );
    try output.print(
        "," ++
            "\"primary_grammar_capacity\":{d}," ++
            "\"primary_identity_capacity\":{d},\"primary_identity_bytes\":{d}," ++
            "\"primary_document_capacity\":{d}," ++
            "\"primary_retained_capacity\":{d},\"final_grammar_capacity\":{d}," ++
            "\"final_identity_capacity\":{d},\"final_identity_bytes\":{d}," ++
            "\"final_document_capacity\":{d},\"final_retained_capacity\":{d}," ++
            "\"reader_live_before_release\":{d}," ++
            "\"reader_live_after_deinit\":{d}," ++
            "\"resolver_allocator_operations\":{d}," ++
            "\"resolver_requested_bytes\":{d},\"resolver_peak_live_bytes\":{d}," ++
            "\"resolver_live_after_documents\":{d}",
        .{
            value.primary_grammar_capacity,
            value.primary_identity_capacity,
            value.primary_identity_bytes,
            value.primary_document_capacity,
            value.primary_retained_capacity,
            value.final_grammar_capacity,
            value.final_identity_capacity,
            value.final_identity_bytes,
            value.final_document_capacity,
            value.final_retained_capacity,
            value.reader_live_before_release,
            value.reader_live_after_deinit,
            value.resolver_allocator_operations,
            value.resolver_requested_bytes,
            value.resolver_peak_live_bytes,
            value.resolver_live_after_documents,
        },
    );
    if (released) {
        try output.print(
            ",\"retained_capacity_after_release\":{d}," ++
                "\"reader_live_after_release\":{d}",
            .{ value.retained_capacity_after_release, value.reader_live_after_release },
        );
    }
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

// --- Tests ---

test "[cli] - [validation repeat]: accepts one primary and one transition schedule" {
    const options = parseOptions(&.{
        "validation-repeat",
        "--dtd=reuse.dtd",
        "--iterations=8",
        "--next-file=small.xml",
        "--next-iterations=4096",
        "--report-memory",
        "--report-timing",
        "--release-memory",
        "large.xml",
    }).?;
    try std.testing.expectEqualStrings("reuse.dtd", options.dtd_name);
    try std.testing.expectEqual(@as(usize, 8), options.iterations);
    try std.testing.expectEqualStrings("small.xml", options.next_name.?);
    try std.testing.expectEqual(@as(usize, 4096), options.next_iterations);
    try std.testing.expect(options.report_memory);
    try std.testing.expect(options.report_timing);
    try std.testing.expect(options.release_memory);
    try std.testing.expectEqualStrings("large.xml", options.path);
}

test "[cli] - [validation repeat]: rejects incomplete or escaping resource arguments" {
    try std.testing.expect(parseOptions(&.{ "validation-repeat", "input.xml" }) == null);
    try std.testing.expect(parseOptions(&.{
        "validation-repeat",
        "--dtd=../reuse.dtd",
        "input.xml",
    }) == null);
    try std.testing.expect(parseOptions(&.{
        "validation-repeat",
        "--dtd=reuse.dtd",
        "--next-file=small.xml",
        "input.xml",
    }) == null);
    try std.testing.expect(parseOptions(&.{
        "validation-repeat",
        "--dtd=reuse.dtd",
        "--release-memory",
        "input.xml",
    }) == null);
}
