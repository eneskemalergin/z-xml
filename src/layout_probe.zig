//! Prints Reader and Document type layouts.

const std = @import("std");
const xml = @import("z_xml");

pub fn main() void {
    std.debug.print(
        "reader\treader={d}\tevent={d}\tattribute={d}\tlocation={d}\n",
        .{
            @sizeOf(xml.Reader),
            @sizeOf(xml.Event),
            @sizeOf(xml.Attribute),
            @sizeOf(xml.Location),
        },
    );
    printPrivate("no-dtd-byte-offset", xml.Configs.XML10_UTF8_NO_DTD_FAST);
    printPrivate("no-dtd-line-column", xml.Configs.XML10_UTF8_NO_DTD);
    printPrivate("no-dtd-namespaces", xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD);
    printPrivate("dtd-process-raw", xml.Configs.XML11_NONVALIDATING);
    printPrivate("dtd-process-namespaces", xml.Configs.XML11_NAMESPACES_NONVALIDATING);
    printPrivate("dtd-validate-namespaces", xml.Configs.XML11_NAMESPACES_VALIDATING);
    std.debug.print(
        "document\tdocument={d}\tnode_index={d}\tnode={d}\telement={d}\t" ++
            "attribute={d}\tnamespace={d}\ttext={d}\ttext_origin={d}\t" ++
            "comment={d}\tpi={d}\tfinding_location={d}\n",
        .{
            @sizeOf(xml.Document),
            @sizeOf(xml.Node),
            @sizeOf(documentListItem("nodes")),
            @sizeOf(documentListItem("elements")),
            @sizeOf(documentListItem("attributes_storage")),
            @sizeOf(documentListItem("namespace_storage")),
            @sizeOf(documentListItem("texts")),
            @sizeOf(documentListItem("text_origins")),
            @sizeOf(documentListItem("comments")),
            @sizeOf(documentListItem("processing_instructions")),
            @sizeOf(xml.Location),
        },
    );
}

fn documentListItem(comptime field_name: []const u8) type {
    const List = @FieldType(xml.Document, field_name);
    return std.meta.Elem(@FieldType(List, "items"));
}

fn printPrivate(comptime name: []const u8, comptime config: xml.Config) void {
    std.debug.print(
        "{s}\treader={d}\tevent={d}\tattribute={d}\tlocation={d}\n",
        .{
            name,
            @sizeOf(xml.ReaderFor(config)),
            @sizeOf(xml.EventFor(config)),
            @sizeOf(xml.AttributeFor(config)),
            @sizeOf(xml.LocationFor(config)),
        },
    );
}
