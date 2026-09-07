//! Isolates public attribute access from caller-owned name classification.
//!
//! Setup parses 64 records and copies their event attributes before advancing the
//! Reader. Timed operations use those owned copies, not parser work or expired
//! event borrows. Each lane checks its exact result before and after measurement.
//! These resident microbenchmarks do not measure complete XML workflows.

const std = @import("std");
const xml = @import("z_xml");

const RECORDS = 64;
const ROUNDS = 256;
const SAMPLES = 5;
const Operation = enum { iterate, raw_lookup, expanded_lookup, classify };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const verify = args.len == 2 and std.mem.eql(u8, args[1], "--verify");
    if (args.len != 1 and !verify) return error.InvalidArguments;
    const rounds: usize = if (verify) 1 else ROUNDS;
    var output_buffer: [4096]u8 = undefined;
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_file.interface;
    try output.writeAll("| Attributes | Names | Operation | Sample | Nanoseconds | Result |\n| ---: | --- | --- | ---: | ---: | ---: |\n");
    for ([_]usize{ 1, 16, 64 }) |width| {
        for ([_]bool{ false, true }) |unique| {
            var arena = std.heap.ArenaAllocator.init(init.gpa);
            defer arena.deinit();
            const allocator = arena.allocator();
            const elements = try prepare(allocator, width, unique);
            const known = elements[0].attributes;
            for (0..if (verify) @as(usize, 1) else SAMPLES + 1) |sample| {
                for (0..4) |index| {
                    const operation: Operation = @enumFromInt((index + sample) % 4);
                    const expected = rounds * if (operation == .classify)
                        width * (width + 1) / 2 * @as(usize, if (unique) 1 else RECORDS)
                    else
                        RECORDS * width;
                    const start = std.Io.Clock.awake.now(init.io);
                    const result = access(elements, known, operation, rounds);
                    const end = std.Io.Clock.awake.now(init.io);
                    if (result != expected) return error.WrongResult;
                    if (sample != 0) try output.print("| {d} | {s} | {s} | {d} | {d} | {d} |\n", .{
                        width,                             if (unique) "unique" else "repeated", @tagName(operation), sample,
                        start.durationTo(end).nanoseconds, result,
                    });
                }
            }
        }
    }
    if (verify) try output.writeAll("Verified 24 access lanes.\n");
    try output.flush();
}

fn prepare(allocator: std.mem.Allocator, width: usize, unique: bool) ![]xml.StartElement {
    var serialized: std.Io.Writer.Allocating = .init(allocator);
    defer serialized.deinit();
    const output = &serialized.writer;
    try output.writeAll("<root>");
    for (0..RECORDS) |record| {
        try output.writeAll("<r");
        for (0..width) |i| try output.print(" a{d:0>4}='v'", .{if (unique) record * width + i else i});
        try output.writeAll("/>");
    }
    try output.writeAll("</root>");
    var reader = try xml.Reader.init(allocator, .{ .slice = serialized.written() }, .{ .dtd = .reject });
    defer reader.deinit();
    const elements = try allocator.alloc(xml.StartElement, RECORDS);
    var count: usize = 0;
    while (try reader.next()) |event| switch (event.data) {
        .start_element => |element| {
            if (element.name.eqlRaw("root")) continue;
            if (!element.name.eql(null, "r") or count == RECORDS or element.attributes.len != width) return error.WrongShape;
            const attributes = try allocator.alloc(xml.Attribute, width);
            for (element.attributes, 0..) |attribute, i| {
                var name_buffer: [16]u8 = undefined;
                const expected = try std.fmt.bufPrint(&name_buffer, "a{d:0>4}", .{if (unique) count * width + i else i});
                if (!attribute.name.eql(null, expected) or !std.mem.eql(u8, attribute.value, "v")) return error.WrongAttribute;
                const raw = try allocator.dupe(u8, attribute.name.raw);
                attributes[i] = .{
                    .name = .{ .raw = raw, .expanded = .{ .prefix = null, .local = raw, .namespace_uri = null } },
                    .value = try allocator.dupe(u8, attribute.value),
                    .span = attribute.span,
                    .specified = attribute.specified,
                    .declared_type = attribute.declared_type,
                };
            }
            elements[count] = .{
                .name = .{ .raw = "r", .expanded = .{ .prefix = null, .local = "r", .namespace_uri = null } },
                .attributes = attributes,
                .namespace_declarations = &.{},
                .empty_syntax = true,
            };
            count += 1;
        },
        else => {},
    };
    if (count != RECORDS) return error.WrongRecordCount;
    return elements;
}

noinline fn access(elements: []const xml.StartElement, known: []const xml.Attribute, operation: Operation, rounds: usize) usize {
    var result: usize = 0;
    for (0..rounds) |_| {
        std.mem.doNotOptimizeAway(elements.ptr);
        for (elements) |element| {
            for (element.attributes) |attribute| {
                switch (operation) {
                    .iterate => result += attribute.value.len,
                    .raw_lookup => result += (element.attributeRaw(attribute.name.raw) orelse return 0).value.len,
                    .expanded_lookup => result += (element.attribute(null, attribute.name.expanded.?.local) orelse return 0).value.len,
                    .classify => {
                        for (known, 0..) |candidate, i| {
                            if (std.mem.eql(u8, candidate.name.raw, attribute.name.raw)) {
                                result += i + 1;
                                break;
                            }
                        }
                    },
                }
            }
            if (operation == .raw_lookup and element.attributeRaw("missing") != null) return 0;
            if (operation == .expanded_lookup and element.attribute(null, "missing") != null) return 0;
        }
    }
    return result;
}
