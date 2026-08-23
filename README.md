# z-xml

Status: **Active** (last updated: 2026-08-23)

`z-xml` is an incremental XML parser for Zig. You can read an XML stream as events or build an immutable document tree from those events. Caller-set limits keep input-driven memory use bounded.

## XML support

- XML 1.0 and XML 1.1
- Raw element and attribute names, or namespace-resolved names
- Parsing without DTD support, DTD processing without validation, or DTD validation
- Internal and external DTD subsets, parameter entities, parsed general entities, declared attributes, content models, IDs, references, notations, and standalone rules
- UTF-8, UTF-16LE, and UTF-16BE input
- Other encodings through a caller-provided `Transcoder`
- Optional XML 1.1 Unicode normalization checks

`Reader(config)` selects the XML version, namespace handling, DTD behavior, event details, and diagnostic locations at compile time. Common choices are available under `Configs`.

The parser never opens files or uses the network on its own. External DTDs and entities require a caller-provided `Resolver`. A validating reader can also reuse a compiled `ExternalSubset` across documents instead of parsing the same external declarations again.

## Package

The public `z_xml` module starts at [`src/root.zig`](src/root.zig). The Zig package contains the library and its self-contained tests. It does not include the development fixtures, tools, benchmark inputs, or downloaded data.

Run the package tests with Zig from `PATH`:

```sh
zig build test
zig build test -Doptimize=ReleaseFast
```

## Development checks

Build an adapter only when a development check needs it:

```sh
zig build --build-file tools/build.zig corpus-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig layout -Doptimize=ReleaseFast
```

Build the local reference parsers once, then run the fixture checks:

```sh
make -C ref all
make -C ref check-corpus
```

The W3C XML Test Suite is a separate, larger check:

```sh
make -C ref all
make -C ref check-xmlconf
```

Some reference parsers disagree with the expected result for known cases, so the reference and W3C commands currently exit with an error after writing their results.

[`fixture/`](fixture/README.md) contains the checked-in validation cases. [`tools/`](tools/README.md) documents the development commands. Local benchmark plans and small inputs live under ignored `bench/`. Generated inputs, downloads, and results live under ignored `data/`.

---

I don't really want to keep using `z-tool` way to name my tools so I probably should think about name ideas for this project, starting with the following:

- prixml: something unique, probablby also bit vague
- zexmel: some what phonetic of z-xml could be of interest
