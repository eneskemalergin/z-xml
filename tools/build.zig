//! Builds development adapters, probes, and their tests.

const std = @import("std");

const CheckAdapter = struct {
    name: []const u8,
    namespaces: bool,
    dtd: bool,
    validating: bool,
};

const PersistentAdapter = struct {
    name: []const u8,
    namespaces: bool,
    default_options: bool,
    namespace_summary: bool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z_xml = b.createModule(.{
        .root_source_file = b.path("../src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run development tool tests");
    const reader_audit_step = b.step(
        "reader-audit",
        "Build and install the Reader resource and failure tests",
    );
    const tree_adapter_step = b.step("tree-adapter", "Build and install the owned-tree adapter");
    const corpus_adapters_step = b.step(
        "corpus-adapters",
        "Build and install the focused corpus adapters",
    );
    const validation_bench_step = b.step(
        "validation-bench",
        "Build and install the fresh and reused validation adapters",
    );
    const persistent_adapters_step = b.step(
        "persistent-adapters",
        "Build and install the qualified persistent adapters",
    );
    const tools_step = b.step("tools", "Build and install all adapter tools");

    const reader_audit_module = b.createModule(.{
        .root_source_file = b.path("../tests/reader.zig"),
        .target = target,
        .optimize = optimize,
        .valgrind = true,
    });
    reader_audit_module.addImport("z_xml", z_xml);
    const reader_audit = b.addTest(.{
        .name = "z-xml-reader-audit",
        .root_module = reader_audit_module,
        .filters = &.{"[Reader"},
    });
    reader_audit_step.dependOn(&b.addInstallArtifact(reader_audit, .{}).step);

    const tree_module = b.createModule(.{
        .root_source_file = b.path("zig/tree.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    tree_module.addImport("z_xml", z_xml);
    const tree_adapter = b.addExecutable(.{
        .name = "z-xml-tree",
        .root_module = tree_module,
    });
    tree_adapter_step.dependOn(&b.addInstallArtifact(tree_adapter, .{}).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tree_module })).step);

    inline for ([_]CheckAdapter{
        .{
            .name = "z-xml-raw-reject-check",
            .namespaces = false,
            .dtd = false,
            .validating = false,
        },
        .{
            .name = "z-xml-namespace-reject-check",
            .namespaces = true,
            .dtd = false,
            .validating = false,
        },
        .{
            .name = "z-xml-raw-process-check",
            .namespaces = false,
            .dtd = true,
            .validating = false,
        },
        .{
            .name = "z-xml-namespace-process-check",
            .namespaces = true,
            .dtd = true,
            .validating = false,
        },
        .{
            .name = "z-xml-raw-validate-check",
            .namespaces = false,
            .dtd = true,
            .validating = true,
        },
        .{
            .name = "z-xml-namespace-validate-check",
            .namespaces = true,
            .dtd = true,
            .validating = true,
        },
    }) |adapter| {
        addCheckAdapter(
            b,
            z_xml,
            target,
            optimize,
            test_step,
            corpus_adapters_step,
            adapter,
        );
    }

    inline for (.{
        .{ "z-xml-validation-fresh", false },
        .{ "z-xml-validation-reused", true },
    }) |adapter| {
        addValidationAdapter(
            b,
            z_xml,
            target,
            optimize,
            test_step,
            validation_bench_step,
            adapter[0],
            adapter[1],
        );
    }

    inline for ([_]PersistentAdapter{
        .{
            .name = "z-xml-persistent",
            .namespaces = false,
            .default_options = false,
            .namespace_summary = false,
        },
        .{
            .name = "z-xml-ns-persistent",
            .namespaces = true,
            .default_options = false,
            .namespace_summary = true,
        },
        .{
            .name = "z-xml-default-persistent",
            .namespaces = true,
            .default_options = true,
            .namespace_summary = false,
        },
    }) |adapter| {
        addPersistentAdapter(
            b,
            z_xml,
            target,
            optimize,
            test_step,
            persistent_adapters_step,
            adapter,
        );
    }

    const layout_module = b.createModule(.{
        .root_source_file = b.path("../src/layout_probe.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    layout_module.addImport("z_xml", z_xml);
    const layout_probe = b.addExecutable(.{
        .name = "z-xml-layout",
        .root_module = layout_module,
    });
    const layout_step = b.step("layout", "Print current Reader and Document layouts");
    layout_step.dependOn(&b.addRunArtifact(layout_probe).step);

    tools_step.dependOn(tree_adapter_step);
    tools_step.dependOn(corpus_adapters_step);
    tools_step.dependOn(validation_bench_step);
    tools_step.dependOn(persistent_adapters_step);
    b.getInstallStep().dependOn(tools_step);
    b.default_step = test_step;
}

fn addCheckAdapter(
    b: *std.Build,
    z_xml: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    install_step: *std.Build.Step,
    adapter: CheckAdapter,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("zig/check.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    module.addImport("z_xml", z_xml);
    const options = b.addOptions();
    options.addOption(bool, "namespaces", adapter.namespaces);
    options.addOption(bool, "dtd", adapter.dtd);
    options.addOption(bool, "validating", adapter.validating);
    module.addOptions("check_options", options);

    const executable = b.addExecutable(.{
        .name = adapter.name,
        .root_module = module,
    });
    install_step.dependOn(&b.addInstallArtifact(executable, .{}).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}

fn addValidationAdapter(
    b: *std.Build,
    z_xml: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    install_step: *std.Build.Step,
    name: []const u8,
    reuse: bool,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("zig/validation_repeat.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    module.addImport("z_xml", z_xml);
    const options = b.addOptions();
    options.addOption(bool, "reuse", reuse);
    module.addOptions("repeat_options", options);

    const executable = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
    install_step.dependOn(&b.addInstallArtifact(executable, .{}).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}

fn addPersistentAdapter(
    b: *std.Build,
    z_xml: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    install_step: *std.Build.Step,
    adapter: PersistentAdapter,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("zig/persistent.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
    });
    module.addImport("z_xml", z_xml);
    const options = b.addOptions();
    options.addOption(bool, "namespaces", adapter.namespaces);
    options.addOption(bool, "default_options", adapter.default_options);
    options.addOption(bool, "namespace_summary", adapter.namespace_summary);
    module.addOptions("persistent_options", options);

    const executable = b.addExecutable(.{
        .name = adapter.name,
        .root_module = module,
    });
    install_step.dependOn(&b.addInstallArtifact(executable, .{}).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}
