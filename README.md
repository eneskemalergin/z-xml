# z-xml

Status: **Active** (last updated: 2026-08-28)

`z-xml` is a Zig library for reading and writing XML. You can read XML as events, parse one complete source into an immutable owned document, or write UTF-8 XML to a caller-owned sink. Caller-set limits keep input-driven memory use bounded.

## XML support

- XML 1.0 and XML 1.1
- Raw element and attribute names, or namespace-resolved names
- Parsing without DTD support, DTD processing without validation, or DTD validation
- Internal and external DTD subsets, parameter entities, parsed general entities, declared attributes, content models, IDs, references, notations, and standalone rules
- UTF-8, UTF-16LE, and UTF-16BE input
- Other root and external-source encodings through a caller-provided `Transcoder`
- Optional XML 1.1 Unicode normalization checks

Normal code calls `Reader.init(allocator, source, options)`. XML version and UTF-8 or UTF-16 decoding are automatic. Namespace, DTD, external-source, transcoding, normalization, line-tracking, diagnostic, and limit choices are runtime options on the same `Reader` and `Event` types.

Code that needs retained XML calls `parseDocument(allocator, source, options)`. It returns one `Document` type regardless of Reader options. The Document owns its retained strings and releases them through `deinit`.

Code that writes XML calls `Writer.init(allocator, sink, options)`. The Writer checks structure, names, namespaces, characters, and escaping. It does not own or flush the sink.

Package tests and development tools that still need a compile-time parser shape use `ReaderFor(config)` and `Configs`.

The Reader never opens files or uses the network on its own. External DTDs and entities require a caller-provided `Resolver`. A validating reader can also reuse a compiled `dtd.ExternalSubset` across documents instead of parsing the same external declarations again.

## Package

The public `z_xml` module starts at [`src/root.zig`](src/root.zig). The Zig package contains the library and its self-contained tests. It does not include the development fixtures, tools, benchmark inputs, or downloaded data.

Run the package tests for the supported execution target with Zig from `PATH`:

```sh
zig build test -Dtarget=x86_64-linux --summary all
zig build test -Dtarget=x86_64-linux -Doptimize=ReleaseFast --summary all
```

## Target support

The package currently supports execution on `x86_64-linux`. Both package test commands above must pass. No compile-only target is claimed, and no support claim is made for another architecture or operating system.

The benchmark host is also Linux x86_64, but benchmark results describe only the recorded host. Development tools, reference parsers, and benchmark adapters do not define package target support.

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
