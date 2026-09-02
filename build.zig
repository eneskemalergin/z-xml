//! Builds the z-xml package and its self-contained tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z_xml = b.addModule("z_xml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const z_xml_profile = b.createModule(.{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
    });

    const reader_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    reader_tests_module.addImport("z_xml_profile", z_xml_profile);

    const tree_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_tests_module.addImport("z_xml_profile", z_xml_profile);

    const writer_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/writer.zig"),
        .target = target,
        .optimize = optimize,
    });
    writer_tests_module.addImport("z_xml", z_xml);

    const reader_tests = b.addTest(.{
        .root_module = reader_tests_module,
    });
    const tree_tests = b.addTest(.{
        .root_module = tree_tests_module,
    });
    const writer_tests = b.addTest(.{
        .root_module = writer_tests_module,
    });
    const reader_internal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/reader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const writer_internal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/writer.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"[writer "},
    });

    const test_step = b.step("test", "Run z-xml package tests");
    test_step.dependOn(&b.addRunArtifact(reader_tests).step);
    test_step.dependOn(&b.addRunArtifact(tree_tests).step);
    test_step.dependOn(&b.addRunArtifact(writer_tests).step);
    test_step.dependOn(&b.addRunArtifact(reader_internal_tests).step);
    test_step.dependOn(&b.addRunArtifact(writer_internal_tests).step);
    b.default_step = test_step;
}
