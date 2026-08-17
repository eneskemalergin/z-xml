//! Builds the z-xml library, public tests, and layout probe.

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
    reader_fixtures.addOption(
        []const u8,
        "mixed_content",
        @embedFile("fixture/valid/core/mixed_content.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "predefined_entities",
        @embedFile("fixture/valid/core/predefined_entities.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "numeric_references",
        @embedFile("fixture/valid/core/numeric_references.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unicode_text",
        @embedFile("fixture/valid/core/unicode_text.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unicode_names",
        @embedFile("fixture/valid/core/unicode_names.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "name_characters",
        @embedFile("fixture/valid/core/name_characters.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_bom",
        @embedFile("fixture/valid/encoding/utf8-bom.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_boundaries",
        @embedFile("fixture/valid/encoding/utf8-codepoint-boundaries.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "cr_line_endings",
        @embedFile("fixture/valid/encoding/cr-line-endings.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "crlf_line_endings",
        @embedFile("fixture/valid/encoding/crlf-line-endings.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "malformed_character_reference",
        @embedFile("fixture/invalid/not_well_formed/malformed_character_reference.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "zero_character_reference",
        @embedFile("fixture/invalid/not_well_formed/zero_character_reference.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "surrogate_character_reference",
        @embedFile("fixture/invalid/not_well_formed/surrogate_character_reference.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "out_of_range_character_reference",
        @embedFile("fixture/invalid/not_well_formed/out_of_range_character_reference.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "undefined_entity",
        @embedFile("fixture/invalid/not_well_formed/undefined_entity.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "truncated_entity",
        @embedFile("fixture/invalid/not_well_formed/truncated_entity.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "cdata_close_in_text",
        @embedFile("fixture/invalid/not_well_formed/cdata_close_in_text.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_lone_continuation",
        @embedFile("fixture/invalid/encoding/utf8-lone-continuation.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_overlong",
        @embedFile("fixture/invalid/encoding/utf8-overlong.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_truncated",
        @embedFile("fixture/invalid/encoding/utf8-truncated.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_surrogate",
        @embedFile("fixture/invalid/encoding/utf8-surrogate.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_out_of_range",
        @embedFile("fixture/invalid/encoding/utf8-out-of-range.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf8_invalid_byte",
        @embedFile("fixture/invalid/encoding/utf8-invalid-byte.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "literal_null",
        @embedFile("fixture/invalid/encoding/literal-null.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "literal_control",
        @embedFile("fixture/invalid/encoding/literal-control.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "declaration",
        @embedFile("fixture/valid/core/declaration.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "prolog_epilog_misc",
        @embedFile("fixture/valid/core/prolog_epilog_misc.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "comment_edges",
        @embedFile("fixture/valid/core/comment_edges.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "processing_instruction",
        @embedFile("fixture/valid/core/processing_instruction.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "cdata",
        @embedFile("fixture/valid/core/cdata.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "declaration_attribute_order",
        @embedFile("fixture/invalid/not_well_formed/declaration_attribute_order.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "declaration_not_first",
        @embedFile("fixture/invalid/not_well_formed/declaration_not_first.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "duplicate_declaration",
        @embedFile("fixture/invalid/not_well_formed/duplicate_declaration.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unsupported_version",
        @embedFile("fixture/invalid/not_well_formed/unsupported_version.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "comment_double_hyphen",
        @embedFile("fixture/invalid/not_well_formed/comment_double_hyphen.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unclosed_comment",
        @embedFile("fixture/invalid/not_well_formed/unclosed_comment.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "reserved_pi_target",
        @embedFile("fixture/invalid/not_well_formed/reserved_pi_target.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "unclosed_cdata",
        @embedFile("fixture/invalid/not_well_formed/unclosed_cdata.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "doctype_after_root",
        @embedFile("fixture/invalid/not_well_formed/doctype_after_root.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "multiple_doctypes",
        @embedFile("fixture/invalid/not_well_formed/multiple_doctypes.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "declared_utf16",
        @embedFile("fixture/invalid/encoding/declared-utf16-but-utf8.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "shape_records",
        @embedFile("fixture/valid/core/shape_records.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ascii_declared",
        @embedFile("fixture/valid/encoding/ascii-declared.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "iso_8859_1",
        @embedFile("fixture/valid/encoding/iso-8859-1.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "declared_ascii_high_byte",
        @embedFile("fixture/invalid/encoding/declared-ascii-with-high-byte.xml"),
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
