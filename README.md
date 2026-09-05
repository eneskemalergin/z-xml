<!-- markdownlint-disable MD033 MD041 -->
<p align="center">
  <img src="assets/z-xml-wordmark.svg" alt="z-xml" width="360">
</p>

<p align="center">
  Bounded XML parsing, owned documents, and streaming UTF-8 writing for Zig.<br>
  One Reader. One Document. One Writer.
</p>

<p align="center">
  <a href="#verification"><img src="https://img.shields.io/badge/tests-352%2F352%20pass-2D7D46?style=flat-square" alt="352 of 352 tests pass"></a>
  <a href="build.zig.zon"><img src="https://img.shields.io/badge/version-v0.2.0-8B5CF6?style=flat-square" alt="v0.2.0"></a>
  <a href="#requirements-and-support"><img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&amp;logo=zig&amp;logoColor=white" alt="Zig 0.16.0"></a>
  <a href="#xml-support"><img src="https://img.shields.io/badge/XML-1.0%20%2B%201.1-0066CC?style=flat-square" alt="XML 1.0 and XML 1.1"></a>
  <a href="#requirements-and-support"><img src="https://img.shields.io/badge/status-active%20development-C17D10?style=flat-square" alt="Active development"></a>
</p>

<!-- markdownlint-enable MD041 -->

---

I built `z-xml` for Zig applications that need explicit ownership, predictable memory use, and control over external input. It reads XML as events, retains complete sources as owned documents, and writes UTF-8 XML through caller-owned sinks.

The package handles XML syntax and XML-level validation. It stays below application frameworks, XSD engines, and domain-specific object mappers.

## What is z-xml?

`z-xml` exposes one normal runtime-policy `Reader`, one immutable owned `Document`, and one bounded streaming `Writer`.

## Highlights

- Incremental XML events from a byte slice or buffered `std.Io.Reader`
- An immutable owned document for applications that need retained structure
- Streaming UTF-8 output through a caller-owned `std.Io.Writer`
- XML 1.0 and XML 1.1 parsing and writing
- Namespace-aware names, attributes, and declarations
- DTD processing and validation, including internal and external subsets
- UTF-8, UTF-16LE, and UTF-16BE input with BOM detection
- A caller-provided transcoder for other source encodings
- Caller-configured limits for tokens, nesting, retained data, DTD work, entities, and output state
- Structured diagnostics, source locations, DTD findings, and memory-usage reporting

## Requirements and support

- Zig 0.16.0
- Supported package execution target: `x86_64-linux`
- No other operating system or architecture is currently claimed
- No external Zig package dependencies

The package is in active development. The API described here is the supported runtime surface.

## Add the package

For a local checkout, add the dependency to the caller's `build.zig.zon`:

```zig
.dependencies = .{
    .z_xml = .{ .path = "../z-xml" },
},
```

Import the module from `build.zig`:

```zig
const z_xml = b.dependency("z_xml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("z_xml", z_xml.module("z_xml"));
```

Application code imports the package as `z_xml`:

```zig
const xml = @import("z_xml");
```

## Read XML as events

Use `Reader` when the application can consume the document in source order without retaining the entire tree:

```zig
const std = @import("std");
const xml = @import("z_xml");

pub fn main() !void {
    const input = "<root id='7'>text<child/></root>";

    var reader = try xml.Reader.init(
        std.heap.page_allocator,
        .{ .slice = input },
        .{ .dtd = .reject },
    );
    defer reader.deinit();

    while (try reader.next()) |event| {
        switch (event.data) {
            .start_element => |element| {
                std.debug.print("start: {s}\n", .{element.name.raw});
            },
            .end_element => |element| {
                std.debug.print("end: {s}\n", .{element.name.raw});
            },
            .text => |text| {
                if (text.bytes.len != 0) {
                    std.debug.print("text: {s}\n", .{text.bytes});
                }
            },
            else => {},
        }
    }
}
```

`Source` accepts either a caller-owned byte slice or a buffered `std.Io.Reader`. The normal reader detects the XML declaration and built-in UTF-8 or UTF-16 encoding. Namespace processing, DTD processing, external-resource blocking, line tracking, and XML 1.1 normalization reporting are controlled by `ReaderOptions`.

Event names, attributes, namespace declarations, and text borrow reader-owned storage. They remain valid until the next read begins, a valid `skipElement` call begins, a successful reset, or `deinit`. Copy borrowed data before that invalidating operation when it must be retained.

The reader reports fatal failures through `ReadError`. Diagnostics and DTD findings can also be retained or sent to caller-provided callbacks. Callbacks are synchronous and cannot re-enter or reset the reader.

## Build an owned document

Use `parseDocument` when the complete structure must remain available after parsing:

```zig
const std = @import("std");
const xml = @import("z_xml");

pub fn readDocument(input: []const u8) !void {
    var document = try xml.parseDocument(
        std.heap.page_allocator,
        .{ .slice = input },
        .{ .reader = .{ .dtd = .reject } },
    );
    defer document.deinit();

    const root = document.documentElement();
    const name = document.nodeName(root) orelse return error.MissingRoot;
    std.debug.print("root: {s}\n", .{name.raw});
}
```

`Document` owns its retained strings, nodes, attributes, namespace declarations, comments, and processing instructions. It exposes indexed navigation through `documentElement`, `children`, `attributes`, `nodeKind`, `nodeName`, and `nodeValue`. The normal document is immutable after construction.

The document retains the structure needed for navigation, not every field produced by the reader. Use reader events when you need event-level source spans, detailed DTD records, or transient event data.

## Write XML

Use `Writer` to emit compact UTF-8 XML to a sink owned by the caller:

```zig
const std = @import("std");
const xml = @import("z_xml");

pub fn writeDocument() !void {
    var output_buffer: [4096]u8 = undefined;
    var sink = std.Io.Writer.fixed(&output_buffer);

    var writer = try xml.Writer.init(
        std.heap.page_allocator,
        &sink,
        .{},
    );
    defer writer.deinit();

    try writer.startDocument();
    try writer.startElement("root");
    try writer.attribute("id", "7");
    try writer.text("value & more");
    try writer.endElement();
    try writer.endDocument();

    std.debug.print("{s}\n", .{sink.buffered()});
}
```

The writer checks call order, XML names, namespace bindings, duplicate attributes, characters, comments, processing instructions, and escaping. It copies names, attributes, and namespace declarations into bounded writer state. It does not own, flush, or deinitialize the sink.

The writer supports XML 1.0 or XML 1.1 UTF-8 output. It does not emit DTD declarations, transcode output to another encoding, pretty-print, or accept unchecked raw markup.

## DTDs and external resources

The reader has three DTD modes:

- `.reject` rejects a document containing a DTD
- `.process` processes DTD declarations and entity behavior without document validation
- `.validate` checks the document against its DTD declarations

The implementation covers internal and external subsets, parameter entities, parsed general entities, declared attributes, content models, IDs, ID references, notations, and standalone-document rules.

External resources are forbidden by default. To resolve an external subset or entity, the caller must explicitly select `.external = .resolve` and provide a `Resolver`. The reader never discovers files, opens paths, or accesses the network on its own. A parsed `dtd.ExternalSubset` can be supplied and reused across documents.

## Namespaces and encodings

Namespace processing is enabled by default. Processed names expose their raw spelling and their expanded prefix, local name, and namespace URI. Set `.namespaces = .raw` when the application needs XML names without Namespaces in XML resolution.

Built-in source handling includes:

- UTF-8
- UTF-16 little endian
- UTF-16 big endian
- XML declarations and BOM detection
- XML 1.0 and XML 1.1 character rules

Other source encodings require a caller-provided `Transcoder`. The writer always emits UTF-8.

## Ownership and limits

`Reader`, `Document`, `Writer`, and `dtd.ExternalSubset` own allocations after successful initialization or construction. Deinitialize each owning value exactly once. Allocators, sources, callback contexts, resolvers, transcoders, and sinks remain caller-owned and must outlive the operations that use them.

Limits are finite and checked before governed storage grows or data is published. At-limit work succeeds. The first item or byte over a configured limit fails with the corresponding error. There is no unlimited preset.

An initialized owning value must not be copied and then independently used or deinitialized. These values are not thread-safe and do not support concurrent or recursive entry.

## Not in scope

`z-xml` is an XML infrastructure layer. It does not provide:

- XML Schema (XSD)
- XPath
- XSLT
- XInclude
- Network fetching or implicit file discovery
- Application object binding
- Domain-specific formats or semantic models
- A guarantee that the writer can reproduce every detail accepted by the reader

## Compatibility

The implementation targets these XML contracts:

- XML 1.0 Fifth Edition
- Namespaces in XML 1.0 Third Edition
- XML 1.1 Second Edition
- Namespaces in XML 1.1 Second Edition
- W3C XML conformance cases relevant to the supported parser modes

Package version `0.2.0` is the current compatibility boundary. The normal `Reader`, `Document`, `Writer`, resolver, transcoder, and DTD contracts are the supported package surface. Before 1.0, an intentional breaking change requires a minor version and a migration note. A conformance correction may change acceptance of input that contradicts the documented XML boundary.

This is a source-package contract, not a stable binary ABI promise.

## Verification

Run the package tests with Zig 0.16 from `PATH`:

```sh
zig build test -Dtarget=x86_64-linux --summary all
zig build test -Dtarget=x86_64-linux -Doptimize=ReleaseFast --summary all
```

The package tests cover the public reader, owned document, writer, XML rules, DTDs, encodings, namespaces, limits, ownership, and round trips.

---

<p align="center"><em>
One stream, one locked tree:<br>
Winter ice bounds every byte;<br>
The cold scribe runs clean.
</em></p>
