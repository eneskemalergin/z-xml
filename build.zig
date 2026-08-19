//! Builds the z-xml library, public tests, corpus adapter, and layout probe.

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
        "utf16le_bom",
        @embedFile("fixture/valid/encoding/utf16le-bom.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf16be_bom",
        @embedFile("fixture/valid/encoding/utf16be-bom.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf16le_odd_byte",
        @embedFile("fixture/invalid/encoding/utf16le-odd-byte.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf16le_unpaired_high",
        @embedFile("fixture/invalid/encoding/utf16le-unpaired-high-surrogate.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "utf16be_unpaired_low",
        @embedFile("fixture/invalid/encoding/utf16be-unpaired-low-surrogate.xml"),
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
    reader_fixtures.addOption(
        []const u8,
        "ns_default",
        @embedFile("fixture/valid/namespaces/default.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_prefixed",
        @embedFile("fixture/valid/namespaces/prefixed.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_rebinding",
        @embedFile("fixture/valid/namespaces/rebinding.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_default_attributes",
        @embedFile("fixture/valid/namespaces/default_does_not_apply_to_attributes.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_xml_prefix",
        @embedFile("fixture/valid/namespaces/xml_prefix.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_default_undeclare",
        @embedFile("fixture/valid/namespaces/default_undeclaration.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_equivalent_uri",
        @embedFile("fixture/valid/namespaces/equivalent_uri_spelling.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_churn",
        @embedFile("fixture/valid/namespaces/shape_namespace_churn.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_unbound_element",
        @embedFile("fixture/invalid/namespaces/unbound_element_prefix.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_unbound_attribute",
        @embedFile("fixture/invalid/namespaces/unbound_attribute_prefix.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_bad_xml_binding",
        @embedFile("fixture/invalid/namespaces/xml_prefix_wrong_uri.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_bad_xmlns_binding",
        @embedFile("fixture/invalid/namespaces/xmlns_prefix_binding.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_xmlns_element",
        @embedFile("fixture/invalid/namespaces/xmlns_as_element_prefix.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_duplicate_expanded",
        @embedFile("fixture/invalid/namespaces/duplicate_expanded_attribute.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_multiple_colons",
        @embedFile("fixture/invalid/namespaces/multiple_colons.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_prefix_undeclare",
        @embedFile("fixture/invalid/namespaces/prefixed_undeclaration.xml"),
    );
    reader_fixtures.addOption(
        []const u8,
        "ns_bad_default_uri",
        @embedFile("fixture/invalid/namespaces/default_bound_to_xmlns_uri.xml"),
    );
    public_tests_module.addOptions("reader_fixtures", reader_fixtures);

    const public_tests = b.addTest(.{
        .root_module = public_tests_module,
    });
    const run_public_tests = b.addRunArtifact(public_tests);

    const test_step = b.step("test", "Run z-xml tests");
    test_step.dependOn(&run_public_tests.step);

    const reader_internal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/reader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_reader_internal_tests = b.addRunArtifact(reader_internal_tests);
    test_step.dependOn(&run_reader_internal_tests.step);

    const dtd_internal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dtd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_dtd_internal_tests = b.addRunArtifact(dtd_internal_tests);
    test_step.dependOn(&run_dtd_internal_tests.step);

    const check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    check_module.addImport("z_xml", z_xml);
    const raw_check_options = b.addOptions();
    raw_check_options.addOption(bool, "namespaces", false);
    raw_check_options.addOption(bool, "general_encodings", false);
    raw_check_options.addOption(bool, "dtd", false);
    raw_check_options.addOption(bool, "validating", false);
    check_module.addOptions("check_options", raw_check_options);
    const check = b.addExecutable(.{
        .name = "z-xml-check",
        .root_module = check_module,
    });
    b.installArtifact(check);
    const check_tests = b.addTest(.{
        .root_module = check_module,
    });
    const run_check_tests = b.addRunArtifact(check_tests);
    test_step.dependOn(&run_check_tests.step);

    const namespace_check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    namespace_check_module.addImport("z_xml", z_xml);
    const namespace_check_options = b.addOptions();
    namespace_check_options.addOption(bool, "namespaces", true);
    namespace_check_options.addOption(bool, "general_encodings", false);
    namespace_check_options.addOption(bool, "dtd", false);
    namespace_check_options.addOption(bool, "validating", false);
    namespace_check_module.addOptions("check_options", namespace_check_options);
    const namespace_check = b.addExecutable(.{
        .name = "z-xml-ns-check",
        .root_module = namespace_check_module,
    });
    b.installArtifact(namespace_check);
    const namespace_check_tests = b.addTest(.{
        .root_module = namespace_check_module,
    });
    const run_namespace_check_tests = b.addRunArtifact(namespace_check_tests);
    test_step.dependOn(&run_namespace_check_tests.step);

    const general_check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    general_check_module.addImport("z_xml", z_xml);
    const general_check_options = b.addOptions();
    general_check_options.addOption(bool, "namespaces", false);
    general_check_options.addOption(bool, "general_encodings", true);
    general_check_options.addOption(bool, "dtd", false);
    general_check_options.addOption(bool, "validating", false);
    general_check_module.addOptions("check_options", general_check_options);
    const general_check = b.addExecutable(.{
        .name = "z-xml-general-check",
        .root_module = general_check_module,
    });
    b.installArtifact(general_check);
    const general_check_tests = b.addTest(.{
        .root_module = general_check_module,
    });
    const run_general_check_tests = b.addRunArtifact(general_check_tests);
    test_step.dependOn(&run_general_check_tests.step);

    const general_namespace_check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    general_namespace_check_module.addImport("z_xml", z_xml);
    const general_namespace_check_options = b.addOptions();
    general_namespace_check_options.addOption(bool, "namespaces", true);
    general_namespace_check_options.addOption(bool, "general_encodings", true);
    general_namespace_check_options.addOption(bool, "dtd", false);
    general_namespace_check_options.addOption(bool, "validating", false);
    general_namespace_check_module.addOptions(
        "check_options",
        general_namespace_check_options,
    );
    const general_namespace_check = b.addExecutable(.{
        .name = "z-xml-general-ns-check",
        .root_module = general_namespace_check_module,
    });
    b.installArtifact(general_namespace_check);
    const general_namespace_check_tests = b.addTest(.{
        .root_module = general_namespace_check_module,
    });
    const run_general_namespace_check_tests = b.addRunArtifact(
        general_namespace_check_tests,
    );
    test_step.dependOn(&run_general_namespace_check_tests.step);

    const dtd_check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    dtd_check_module.addImport("z_xml", z_xml);
    const dtd_check_options = b.addOptions();
    dtd_check_options.addOption(bool, "namespaces", false);
    dtd_check_options.addOption(bool, "general_encodings", true);
    dtd_check_options.addOption(bool, "dtd", true);
    dtd_check_options.addOption(bool, "validating", false);
    dtd_check_module.addOptions("check_options", dtd_check_options);
    const dtd_check = b.addExecutable(.{
        .name = "z-xml-dtd-check",
        .root_module = dtd_check_module,
    });
    b.installArtifact(dtd_check);
    const dtd_check_tests = b.addTest(.{ .root_module = dtd_check_module });
    test_step.dependOn(&b.addRunArtifact(dtd_check_tests).step);

    const dtd_namespace_check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    dtd_namespace_check_module.addImport("z_xml", z_xml);
    const dtd_namespace_check_options = b.addOptions();
    dtd_namespace_check_options.addOption(bool, "namespaces", true);
    dtd_namespace_check_options.addOption(bool, "general_encodings", true);
    dtd_namespace_check_options.addOption(bool, "dtd", true);
    dtd_namespace_check_options.addOption(bool, "validating", false);
    dtd_namespace_check_module.addOptions("check_options", dtd_namespace_check_options);
    const dtd_namespace_check = b.addExecutable(.{
        .name = "z-xml-dtd-ns-check",
        .root_module = dtd_namespace_check_module,
    });
    b.installArtifact(dtd_namespace_check);
    const dtd_namespace_check_tests = b.addTest(.{ .root_module = dtd_namespace_check_module });
    test_step.dependOn(&b.addRunArtifact(dtd_namespace_check_tests).step);

    const validating_check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    validating_check_module.addImport("z_xml", z_xml);
    const validating_check_options = b.addOptions();
    validating_check_options.addOption(bool, "namespaces", false);
    validating_check_options.addOption(bool, "general_encodings", true);
    validating_check_options.addOption(bool, "dtd", true);
    validating_check_options.addOption(bool, "validating", true);
    validating_check_module.addOptions("check_options", validating_check_options);
    const validating_check = b.addExecutable(.{
        .name = "z-xml-validating-check",
        .root_module = validating_check_module,
    });
    b.installArtifact(validating_check);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = validating_check_module })).step);

    const validating_namespace_check_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    validating_namespace_check_module.addImport("z_xml", z_xml);
    const validating_namespace_check_options = b.addOptions();
    validating_namespace_check_options.addOption(bool, "namespaces", true);
    validating_namespace_check_options.addOption(bool, "general_encodings", true);
    validating_namespace_check_options.addOption(bool, "dtd", true);
    validating_namespace_check_options.addOption(bool, "validating", true);
    validating_namespace_check_module.addOptions(
        "check_options",
        validating_namespace_check_options,
    );
    const validating_namespace_check = b.addExecutable(.{
        .name = "z-xml-validating-ns-check",
        .root_module = validating_namespace_check_module,
    });
    b.installArtifact(validating_namespace_check);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = validating_namespace_check_module,
    })).step);

    inline for (.{
        .{ "z-xml-validation-fresh", false },
        .{ "z-xml-validation-reused", true },
    }) |entry| {
        const repeat_module = b.createModule(.{
            .root_source_file = b.path("tools/z_xml_validation_repeat.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseFast,
        });
        repeat_module.addImport("z_xml", z_xml);
        const repeat_options = b.addOptions();
        repeat_options.addOption(bool, "reuse", entry[1]);
        repeat_module.addOptions("repeat_options", repeat_options);
        const repeat = b.addExecutable(.{
            .name = entry[0],
            .root_module = repeat_module,
        });
        b.installArtifact(repeat);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = repeat_module })).step);
    }

    const persistent_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_persistent.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    persistent_module.addImport("z_xml", z_xml);
    const persistent_raw_options = b.addOptions();
    persistent_raw_options.addOption(bool, "namespaces", false);
    persistent_raw_options.addOption(bool, "general_encodings", false);
    persistent_module.addOptions("persistent_options", persistent_raw_options);
    const persistent = b.addExecutable(.{
        .name = "z-xml-persistent",
        .root_module = persistent_module,
    });
    b.installArtifact(persistent);
    const persistent_tests = b.addTest(.{
        .root_module = persistent_module,
    });
    const run_persistent_tests = b.addRunArtifact(persistent_tests);
    test_step.dependOn(&run_persistent_tests.step);

    const namespace_persistent_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_persistent.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    namespace_persistent_module.addImport("z_xml", z_xml);
    const persistent_namespace_options = b.addOptions();
    persistent_namespace_options.addOption(bool, "namespaces", true);
    persistent_namespace_options.addOption(bool, "general_encodings", false);
    namespace_persistent_module.addOptions(
        "persistent_options",
        persistent_namespace_options,
    );
    const namespace_persistent = b.addExecutable(.{
        .name = "z-xml-ns-persistent",
        .root_module = namespace_persistent_module,
    });
    b.installArtifact(namespace_persistent);
    const namespace_persistent_tests = b.addTest(.{
        .root_module = namespace_persistent_module,
    });
    const run_namespace_persistent_tests = b.addRunArtifact(namespace_persistent_tests);
    test_step.dependOn(&run_namespace_persistent_tests.step);

    const general_persistent_module = b.createModule(.{
        .root_source_file = b.path("tools/z_xml_persistent.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    general_persistent_module.addImport("z_xml", z_xml);
    const general_persistent_options = b.addOptions();
    general_persistent_options.addOption(bool, "namespaces", false);
    general_persistent_options.addOption(bool, "general_encodings", true);
    general_persistent_module.addOptions("persistent_options", general_persistent_options);
    const general_persistent = b.addExecutable(.{
        .name = "z-xml-general-persistent",
        .root_module = general_persistent_module,
    });
    b.installArtifact(general_persistent);
    const general_persistent_tests = b.addTest(.{
        .root_module = general_persistent_module,
    });
    const run_general_persistent_tests = b.addRunArtifact(general_persistent_tests);
    test_step.dependOn(&run_general_persistent_tests.step);

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
