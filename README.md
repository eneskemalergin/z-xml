# z-xml

Status: **Active** (last updated: 2026-09-01)

`z-xml` is a Zig library for reading and writing XML. You can read XML as events, parse one complete source into an immutable owned document, or write UTF-8 XML to a caller-owned sink. Caller-set limits keep input-driven memory use bounded.

## Add the package

The package name and imported module are both `z_xml`. For a local checkout, add the dependency to the caller's `build.zig.zon`:

```zig
.dependencies = .{
    .z_xml = .{ .path = "../z-xml" },
},
```

Import its module in the caller's `build.zig`:

```zig
const z_xml = b.dependency("z_xml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("z_xml", z_xml.module("z_xml"));
```

Application code then imports the module:

```zig
const xml = @import("z_xml");
```

The package contains `build.zig`, `build.zig.zon`, `src/`, and self-contained `tests/`. It does not contain development fixtures, tools, reference parsers, benchmark inputs, generated data, or plans.

## Read events

Use the normal `Reader` for streaming work:

```zig
var reader = try xml.Reader.init(
    allocator,
    .{ .slice = input },
    .{ .dtd = .reject },
);
defer reader.deinit();

while (try reader.next()) |event| switch (event.data) {
    .start_element => |element| {
        _ = element.name;
        _ = element.attributes;
    },
    .text => |text| _ = text.bytes,
    else => {},
};
```

`Source` accepts a caller-owned byte slice or buffered `std.Io.Reader`. XML edition and built-in UTF-8 or UTF-16 decoding are automatic. The default options process namespaces and DTD effects, forbid external resources, track lines, and report XML 1.1 normalization findings.

Set `dtd = .reject` for a format that forbids DTDs. Set `dtd = .{ .validate = .{} }` for DTD validation. Resolving an external DTD or entity that the caller has not already supplied requires `external = .resolve` and a caller-provided `Resolver`; the Reader never opens files or uses the network on its own. Set `namespaces = .raw` only when the caller needs raw XML names without Namespaces in XML processing. A caller-provided `Transcoder` handles other root or external-source encodings.

Event strings, attributes, and namespace declarations borrow Reader storage. They remain valid until the next `next` call begins, a valid `skipElement` call begins, a reset succeeds, or the Reader is deinitialized. A failed reset, an invalid `skipElement` call, and read-only calls do not invalidate them.

Values returned by `diagnostic`, `firstDtdFinding`, and `normalizationFinding` remain valid until reset succeeds or the Reader is deinitialized. This includes the diagnostic and DTD-finding inclusion traces. Values passed to diagnostic and DTD-finding callbacks are valid only during the callback. Copy borrowed data before its invalidating call when it must be retained.

## Build an owned document

Use `parseDocument` when the complete retained structure is needed:

```zig
var document = try xml.parseDocument(
    allocator,
    .{ .slice = input },
    .{ .reader = .{ .dtd = .reject } },
);
defer document.deinit();

const root = document.documentElement();
const name = document.nodeName(root) orelse return error.MissingRoot;
_ = name;
```

The returned `Document` owns its retained strings and arrays. Node indexes and values returned by its query methods are scoped to that Document and remain valid until `deinit`. The normal Document is immutable. It does not retain physical source spans, detailed DTD records, or every Reader event field; use Reader events when those details are required.

## Write XML

Use `Writer` to emit compact UTF-8 XML to a caller-owned `std.Io.Writer`:

```zig
var writer = try xml.Writer.init(allocator, &sink, .{});
defer writer.deinit();

try writer.startDocument();
try writer.startElement("root");
try writer.attribute("id", "1");
try writer.text("value");
try writer.endElement();
try writer.endDocument();

try sink.flush();
```

The Writer checks call order, XML names, namespace bindings, duplicate attributes, characters, comments, processing instructions, and escaping. It owns bounded temporary state but does not own, close, deinitialize, or flush the sink. It writes XML 1.0 or XML 1.1 in UTF-8. It does not write DTD declarations, other encodings, indentation, or raw unchecked markup.

## Ownership and limits

`Reader`, `Document`, `Writer`, and `dtd.ExternalSubset` values own allocations after successful initialization or construction and must be deinitialized exactly once. Their allocators, caller-owned sources, callback contexts, resolvers, transcoders, and sinks must remain valid for the lifetimes stated by their APIs. Copying a live owning value and using or deinitializing both copies is unsupported.

The normal Reader, Document, Writer, resolver, transcoder, DTD, validation, and retained-finding paths use finite defaults. Limits are checked before governed growth or publication. At-limit work succeeds; the first item or byte over the limit fails with the owning error. There is no unlimited preset.

## XML support

- XML 1.0 and XML 1.1
- Raw element and attribute names, or namespace-resolved names
- Parsing without DTD support, DTD processing without validation, or DTD validation
- Internal and external DTD subsets, parameter entities, parsed general entities, declared attributes, content models, IDs, references, notations, and standalone rules
- UTF-8, UTF-16LE, and UTF-16BE input
- Other root and external-source encodings through a caller-provided `Transcoder`
- Optional XML 1.1 Unicode normalization checks

`Config`, `Configs`, and names exported by `src/root.zig` that contain `Profile` or end in `For` are explicit compile-time specialization surfaces. Package tests and development tools use them. Normal application code should use `Reader`, `Event`, `Document`, and `Writer` unless it has a measured need for a fixed shape.

A validating Reader can reuse a compiled `dtd.ExternalSubset` across documents instead of parsing the same external declarations again.

XSD, XPath, XSLT, XInclude, application object binding, implicit file discovery, and network fetching are outside the package. The Writer does not imply support for serializing every feature accepted by the Reader.

## Version and compatibility

Package version `0.1.0` is the first frozen source-compatibility boundary. Every declaration exported by [`src/root.zig`](src/root.zig) is public. Within `0.1.x`, patch releases preserve exported names, call signatures, ownership rules, and documented successful behavior. An XML conformance correction may change acceptance of input that contradicted the documented standards boundary and will be identified as a correction.

Before 1.0, an intentional breaking change requires a minor version and a migration note. This is a Zig source-package contract, not a stable binary ABI. Changing the supported Zig version or target policy also requires an explicit compatibility decision.

## Package checks

Run the package tests for the supported execution target with Zig from `PATH`:

```sh
zig build test -Dtarget=x86_64-linux --summary all
zig build test -Dtarget=x86_64-linux -Doptimize=ReleaseFast --summary all
```

## Target support

The package requires Zig 0.16 and currently supports execution on `x86_64-linux`. Both package test commands above must pass. No compile-only target is claimed, and no support claim is made for another architecture or operating system.

The benchmark host is also Linux x86_64, but benchmark results describe only the recorded host. Development tools, reference parsers, and benchmark adapters do not define package target support.

## Development checks

Development fixtures, peer parsers, conformance runs, resource checks, generated corpora, and measurements are separate from the package. The main correctness commands are:

```sh
make -C ref smoke
make -C ref check-corpus
make -C ref check-reader-conformance
```

[`fixture/`](fixture/README.md) defines the checked-in validation cases. [`ref/`](ref/README.md) documents reference parsers and their result rules. [`tools/`](tools/README.md) owns adapter, corpus, conformance, Valgrind, and Zebrac commands. Local benchmark plans and small inputs live under ignored `bench/`. Generated inputs, downloads, and results live under ignored `data/`.

---

I don't really want to keep using `z-tool` way to name my tools so I probably should think about name ideas for this project, starting with the following:

- prixml: something unique, probablby also bit vague
- zexmel: some what phonetic of z-xml could be of interest
