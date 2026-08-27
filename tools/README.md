# Tools

Status: **Active** (last updated: 2026-08-25)

`tools/` contains development commands and parser adapters. It is excluded from the Zig package.

Files are grouped by language. The Python commands remain direct scripts, so they need no wrappers or package files.

- `build.zig` builds the Zig adapters and layout probe.
- `zig/` contains adapter source code compiled by `build.zig`.
- `python/` contains directly executable checks, generators, and measurement commands.
- `targets.tsv` describes the z-xml adapter capabilities used by fixture checks.
- `fetch-w3c-xmlconf.sh` downloads the pinned W3C suite. It stays at the root because it is the only shell command.

Use `make -C ref` for commands that work with fixtures, generated XML, or reference parsers. Use `zig build --build-file tools/build.zig` to build the z-xml adapters.

## Commands

Fixture checks:

- `make -C ref check-byte-fixtures` checks that byte-sensitive fixture files match their generator.
- `make -C ref check-corpus` runs each fixture through the parsers that support its XML features.
- `make -C ref check-reader-conformance` runs the focused and W3C cases applicable to the six z-xml Reader profiles.

Local benchmark checks:

- `make -C ref check-shape-matrix` checks the local workload plan and its fixture references.
- `make -C ref check-persistent` checks repeated parsing with a small local input.

Generated XML:

- `make -C ref generate-corpus check-generated` generates valid and malformed XML, then checks parser output.
- `make -C ref generate-namespace-corpus verify-namespace-corpus` generates XML with frequent namespace changes, then checks it.
- `make -C ref check-generated-persistent` checks repeated parsing from memory and from a stream.
- `make -C ref check-reader-scale` checks semantic output and parser-owned memory for the default Reader on increasing flat and bounded-depth streams.

Standard test data:

- `make -C ref check-unicode-table` checks the XML 1.1 Unicode normalization table stored in the repository.
- `make -C ref fetch-xmlconf check-xmlconf` downloads the selected W3C XML Test Suite and runs the supported cases.

Measurement:

- `tools/python/run-zebrac-aa.py` runs the same command under two names to measure machine noise.
- `tools/python/run-zebrac-matrix.py` measures parser and workload pairs that passed their required checks.
- `tools/python/run-valgrind.py` checks correctness-passing corpus cases or an explicit standalone test executable for memory errors and leaked file descriptors. Tracked fixture cases keep companion external sources beside the selected XML file.

`bench/` and `data/` are ignored. `bench/` contains local plans and small benchmark inputs. `data/` contains generated XML, downloaded test suites, and results. Benchmark results are local until the project has a stable way to reproduce and compare them.

## Zig adapters

- `tools/zig/check.zig` reads XML and prints event counts and a checksum.
- `tools/zig/persistent.zig` measures repeated parsing from memory or a stream. The `z-xml-default-persistent` build uses `Reader.init` defaults.
- `tools/zig/tree.zig` builds and walks the public owned `Document`. Its normal output reports node-kind counts, depth, a Reader-compatible common checksum, and a traversal checksum that includes comments and processing instructions. Timing mode uses the full traversal checksum. Memory mode reports retained capacity, construction peak and allocation operations, and traversal scratch peak and allocation operations separately.
- `tools/zig/validation_repeat.zig` compares validation with a new or reused external DTD subset.

The persistent adapter gives resident input to `Reader` as one slice. `--chunk-bytes` sizes the buffered file reader only for stream input. The resident result keeps the requested value in its protocol metadata, so resident rows with different chunk values are not different source schedules.

Build only the adapters you need:

```sh
zig build --build-file tools/build.zig corpus-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig tree-adapter -Doptimize=ReleaseFast
zig build --build-file tools/build.zig validation-bench -Doptimize=ReleaseFast
zig build --build-file tools/build.zig reader-audit -Doptimize=Debug
```

The `tools` build step installs every adapter. The `test` step runs tests for the tool code. The separate `reader-audit` step installs the Reader test executable used for Memcheck; it is not part of the adapter union.

Run that executable under Memcheck with:

```sh
tools/python/run-valgrind.py \
    --output-dir data/results/reader-audit \
    --standalone tools/zig-out/bin/z-xml-reader-audit
```

Standalone mode writes `standalone.log`. Corpus mode keeps its existing metadata and result files.

The Reader audit runs all 67 tests under Memcheck. Its fuzz helper uses heap storage for the Reader in this build because Valgrind reports Zig's Debug stack page probes as invalid reads. Normal tests and fuzz campaigns keep stack storage.

The development build installs adapters under `tools/zig-out/bin` by default.

## Target lists

`tools/targets.tsv` lists the z-xml reader configurations used by the fixture checker. `ref/targets.tsv` lists the reference parsers and the XML features each one supports. `ref/persistent-targets.tsv` lists the parsers used for repeated-input checks.

The measurement scripts use `zebrac` from `PATH` by default. Pass `--zebrac PATH` to use another executable. `ref/build.sh` downloads and builds reference parsers in its local cache when needed.
