"""Run public workflows from Zig's admitted package in an isolated dependent build."""

import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

BUILD = """//! Exercises the dependency's public XML workflows.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("z_xml", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("workflows.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("z_xml", dependency.module("z_xml"));
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run dependency workflows").dependOn(&b.addRunArtifact(tests).step);
}
"""


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="z-xml-workflows-") as temporary:
        directory = Path(temporary)
        cache = directory / "cache"
        staged = directory / "package"
        staged.mkdir()
        for name in ("build.zig", "build.zig.zon", "src", "tests"):
            source = root / name
            if source.is_dir():
                shutil.copytree(source, staged / name)
            else:
                shutil.copy2(source, staged / name)
        consumer = directory / "consumer"
        consumer.mkdir()
        print(
            "Packaging admitted source roots for dependency qualification", flush=True
        )
        fetched = subprocess.run(
            ["zig", "fetch", "--global-cache-dir", str(cache), str(staged)],
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
        package_id = fetched.stdout.strip()
        archive = cache / "p" / f"{package_id}.tar.gz"
        with tarfile.open(archive) as package:
            for member in package.getmembers():
                path = PurePosixPath(member.name).relative_to(package_id)
                if path.parts and path.parts[0] not in {
                    "build.zig",
                    "build.zig.zon",
                    "src",
                    "tests",
                }:
                    raise RuntimeError(f"unexpected package member: {path}")
            workflows = package.extractfile(f"{package_id}/tests/workflows.zig")
            if workflows is None:
                raise RuntimeError("workflow suite is absent from the package")
            with workflows:
                (consumer / "workflows.zig").write_bytes(workflows.read())
        subprocess.run(
            ["zig", "init", "--minimal"], cwd=consumer, check=True, timeout=30
        )
        (consumer / "build.zig").write_text(BUILD)
        subprocess.run(
            [
                "zig",
                "fetch",
                "--global-cache-dir",
                str(cache),
                "--save=z_xml",
                str(archive),
            ],
            cwd=consumer,
            check=True,
            timeout=120,
        )
        for mode in ("Debug", "ReleaseFast"):
            print(f"Public package workflows: {mode}", flush=True)
            subprocess.run(
                [
                    "zig",
                    "build",
                    "test",
                    "-Dtarget=x86_64-linux",
                    f"-Doptimize={mode}",
                    "--global-cache-dir",
                    str(cache),
                    "--summary",
                    "all",
                ],
                cwd=consumer,
                check=True,
                timeout=600,
            )
        print("Public package workflows passed in both modes.", flush=True)


if __name__ == "__main__":
    main()
