# Tools

Status: **Active** (last updated: 2026-08-23)

`tools/` contains the scripts and small Zig programs used to test the parser, generate test data, and measure performance. They are development tools and are not included in the Zig package.

Use `make -C ref` for commands that work with fixtures, generated XML, or reference parsers. Use `zig build --build-file tools/build.zig` to build the z-xml adapters.

## Commands

Fixture checks:

- `make -C ref check-byte-fixtures` checks that byte-sensitive fixture files match their generator.
- `make -C ref check-corpus` runs each fixture through the parsers that support its XML features.

Local benchmark checks:

- `make -C ref check-shape-matrix` checks the local workload plan and its fixture references.
- `make -C ref check-persistent` checks repeated parsing with a small local input.

Generated XML:

- `make -C ref generate-corpus check-generated` generates valid and malformed XML, then checks parser output.
- `make -C ref generate-namespace-corpus verify-namespace-corpus` generates XML with frequent namespace changes, then checks it.
- `make -C ref check-generated-persistent` checks repeated parsing from memory and from a stream.

Standard test data:

- `make -C ref check-unicode-table` checks the XML 1.1 Unicode normalization table stored in the repository.
- `make -C ref fetch-xmlconf check-xmlconf` downloads the selected W3C XML Test Suite and runs the supported cases.

Measurement:

- `run-zebrac-aa.py` runs the same command under two names to measure machine noise.
- `run-zebrac-matrix.py` measures parser and workload pairs that passed their required checks.
- `run-valgrind.py` checks selected passing cases for memory errors.

`bench/` and `data/` are ignored. `bench/` contains local plans and small benchmark inputs. `data/` contains generated XML, downloaded test suites, and results. Benchmark results are local until the project has a stable way to reproduce and compare them.

## Zig adapters

- `z_xml_check.zig` reads XML and prints event counts and a checksum.
- `z_xml_persistent.zig` measures repeated parsing from memory or a stream.
- `z_xml_tree.zig` builds and walks an owned document tree.
- `z_xml_validation_repeat.zig` compares validation with a new or reused external DTD subset.

Build only the adapters you need:

```sh
zig build --build-file tools/build.zig corpus-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig tree-adapter -Doptimize=ReleaseFast
zig build --build-file tools/build.zig validation-bench -Doptimize=ReleaseFast
```

The `tools` build step installs every adapter. The `experimental-adapters` step installs adapters that do not yet have a fully checked workload. The `test` step runs tests for the tool code.

## Target lists

`tools/z-xml-targets.tsv` lists the z-xml reader configurations used by the fixture checker. `ref/targets.tsv` lists the reference parsers and the XML features each one supports. `ref/persistent-targets.tsv` lists the parsers used for repeated-input checks.

The measurement scripts use `zebrac` from `PATH` by default. Pass `--zebrac PATH` to use another executable. `ref/build.sh` downloads and builds reference parsers in its local cache when needed.
