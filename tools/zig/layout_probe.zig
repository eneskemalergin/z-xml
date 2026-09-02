//! Prints Reader and Document type layouts.

const std = @import("std");
const profile = @import("z_xml_profile");
const xml = profile.api;

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
    printPrivate("no-dtd-byte-offset", profile.Configs.XML10_UTF8_NO_DTD_FAST);
    printPrivate("no-dtd-line-column", profile.Configs.XML10_UTF8_NO_DTD);
    printPrivate("no-dtd-namespaces", profile.Configs.XML10_UTF8_NAMESPACES_NO_DTD);
    printPrivate("dtd-process-raw", profile.Configs.XML11_NONVALIDATING);
    printPrivate("dtd-process-namespaces", profile.Configs.XML11_NAMESPACES_NONVALIDATING);
    printPrivate("dtd-validate-namespaces", profile.Configs.XML11_NAMESPACES_VALIDATING);
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

fn printPrivate(comptime name: []const u8, comptime config: profile.Config) void {
    std.debug.print(
        "{s}\treader={d}\tevent={d}\tattribute={d}\tlocation={d}\n",
        .{
            name,
            @sizeOf(profile.ReaderFor(config)),
            @sizeOf(profile.EventFor(config)),
            @sizeOf(profile.AttributeFor(config)),
            @sizeOf(profile.LocationFor(config)),
        },
    );
}
