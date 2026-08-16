const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z_xml = b.addModule("z_xml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const public_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_tests_module.addImport("z_xml", z_xml);
    const reader_fixtures = b.addOptions();
    reader_fixtures.addOption(
        []const u8,
        "nested",
        @embedFile("fixture/valid/core/nested.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "empty_explicit",
        @embedFile("fixture/valid/core/empty_explicit.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "mismatched",
        @embedFile("fixture/invalid/not_well_formed/mismatched_tags.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unexpected_end",
        @embedFile("fixture/invalid/not_well_formed/unexpected_end.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unclosed",
        @embedFile("fixture/invalid/not_well_formed/unclosed_element.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "end_space",
        @embedFile("fixture/invalid/not_well_formed/space_in_end_tag.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "attributes",
        @embedFile("fixture/valid/core/attributes.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "attribute_normalization",
        @embedFile("fixture/valid/core/attribute_normalization.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "duplicate_attribute",
        @embedFile("fixture/invalid/not_well_formed/duplicate_attribute.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unquoted_attribute",
        @embedFile("fixture/invalid/not_well_formed/unquoted_attribute.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "missing_equals",
        @embedFile("fixture/invalid/not_well_formed/missing_equals.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "attribute_lt",
        @embedFile("fixture/invalid/not_well_formed/attribute_lt.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "truncated_attribute",
        @embedFile("fixture/invalid/not_well_formed/truncated_attribute.xml"),
    );
    public_tests_module.addOptions("reader_fixtures", reader_fixtures);

    const public_tests = b.addTest(.{
        .root_module = public_tests_module,
    });
    const run_public_tests = b.addRunArtifact(public_tests);

    const test_step = b.step("test", "Run public z-xml tests");
    test_step.dependOn(&run_public_tests.step);

    const layout_module = b.createModule(.{
        .root_source_file = b.path("src/layout_probe.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    layout_module.addImport("z_xml", z_xml);

    const layout_probe = b.addExecutable(.{
        .name = "z-xml-layout",
        .root_module = layout_module,
    });
    const run_layout_probe = b.addRunArtifact(layout_probe);

    const layout_step = b.step("layout", "Print representative specialized type layouts");
    layout_step.dependOn(&run_layout_probe.step);
}
