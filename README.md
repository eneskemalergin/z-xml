# z-xml

Status: **Active** (last updated: 2026-08-23)

`z-xml` is a compile-time-specialized streaming XML library for Zig. The repository also contains a separate qualification laboratory: conformance data, matched workloads, and reproducible peer builds keep correctness and performance claims measurable without becoming library dependencies.

The repository contains qualified raw-name and namespace-aware XML 1.0 and XML 1.1 readers for non-validating and DTD-validating input, plus specialized XML 1.0 no-DTD readers. DTD readers parse internal and external subsets, apply parameter and general parsed entities, normalize and default declared attributes, and enforce bounded declaration, grammar, comparison, recursion, expansion, resolver, and validation work. Validating readers check content models, declared attributes, tokenized types, IDs and references, notations, root agreement, and standalone constraints. XML 1.1 readers verify Unicode full normalization with advisory and strict policies plus an unchecked mode reserved for certified input. UTF-8, UTF-16LE, and UTF-16BE sources are built in. Other external-source encodings require a caller-supplied transcoder. External access requires a caller-owned resolver and grants no implicit filesystem or network authority. A compact immutable owned tree is built from the same public event stream.

Repeated validation may attach a caller-owned immutable `ExternalSubset` compiled from decoded, line-normalized UTF-8 declarations. Per-document internal declarations retain precedence. Fresh and reused validation have the same semantic and diagnostic contract; reuse avoids reparsing and recompiling an unchanged external grammar.

Run the library tests with the configured Zig toolchain:

```sh
zig build test
zig build test -Doptimize=ReleaseFast
```

Build qualification adapters only when the corresponding workflow needs them:

```sh
zig build --build-file tools/build.zig corpus-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
zig build --build-file tools/build.zig layout -Doptimize=ReleaseFast
```

The library surface is the `z_xml` module rooted at [`src/root.zig`](src/root.zig). The checked-in fixtures, [`tools/`](tools/README.md), and local reference laboratory in [`ref/`](ref/README.md) qualify it; they are qualification inputs, not runtime dependencies. Detailed XML support, API, engine, and consumer design is in [`plan/idea/`](plan/idea/README.md).

The two test commands above cover the library. The remaining commands are qualification and measurement workflows.

Build every reference once, then run the focused correctness gate:

```sh
make -C ref all
make -C ref check-corpus
```

Build and verify the host-tuned binaries and deterministic performance corpus before zebrac:

```sh
make -C ref all
make -C ref smoke
make -C ref check-generated
```

Generate and verify the full 1 MiB through 1 GiB matrix separately. It occupies about 10.3 GiB and is not committed:

```sh
make -C ref all
make -C ref generate-corpus-full verify-corpus-full
```

Build and verify the maintained persistent protocols and their generated inputs:

```sh
zig build --build-file tools/build.zig persistent-adapters -Doptimize=ReleaseFast
make -C ref all
make -C ref generate-corpus-persistent generate-namespace-corpus
make -C ref check-generated-persistent
```

Fetch and check the official W3C XML Test Suite separately:

```sh
make -C ref all
make -C ref check-xmlconf
```

The focused peer corpus and W3C checks expose known reference-parser disagreements and exit nonzero. Generated and real benchmark artifacts are not committed, and Zebrac measurements wait until each selected workload passes its declared correctness profile and exact-output gate. The reference builder and Zebrac wrappers use the configured project commands; the wrappers also accept an explicit `--zebrac` override.

---

I don't really want to keep using `z-tool` way to name my tools so I probably should think about name ideas for this project, starting with the following:

- prixml: something unique, probablby also bit vague
- zexmel: some what phonetic of z-xml could be of interest
