//! Prints type layouts for the specialization evidence log.

const std = @import("std");
const xml = @import("z_xml");

pub fn main() void {
    printLayout("xml10-utf8-no-dtd-fast", xml.Configs.XML10_UTF8_NO_DTD_FAST);
    printLayout("xml10-utf8-no-dtd", xml.Configs.XML10_UTF8_NO_DTD);
    printLayout("xml10-utf8-no-dtd-located", xml.Configs.XML10_UTF8_NO_DTD_LOCATED);
    printLayout("xml10-utf8-ns-no-dtd", xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD);
    printLayout(
        "xml10-utf8-ns-no-dtd-fast",
        xml.Configs.XML10_UTF8_NAMESPACES_NO_DTD_FAST,
    );
    printLayout("xml10-no-dtd", xml.Configs.XML10_NO_DTD);
    printLayout("xml10-no-dtd-fast", xml.Configs.XML10_NO_DTD_FAST);
    printLayout("xml10-ns-no-dtd", xml.Configs.XML10_NAMESPACES_NO_DTD);
    printLayout(
        "xml10-ns-no-dtd-fast",
        xml.Configs.XML10_NAMESPACES_NO_DTD_FAST,
    );
    printLayout("xml10-nonvalidating", xml.Configs.XML10_NONVALIDATING);
    printLayout("xml10-validating", xml.Configs.XML10_VALIDATING);
    printLayout(
        "xml10-ns-validating-detailed",
        xml.Configs.XML10_NAMESPACES_VALIDATING_DETAILED,
    );
    printLayout("xml11-ns-validating", xml.Configs.XML11_NAMESPACES_VALIDATING);
}

fn printLayout(comptime name: []const u8, comptime config: xml.Config) void {
    std.debug.print(
        "{s}\treader={d}\tevent={d}\tattribute={d}\tlocation={d}\n",
        .{
            name,
            @sizeOf(xml.Reader(config)),
            @sizeOf(xml.Event(config)),
            @sizeOf(xml.Attribute(config)),
            @sizeOf(xml.Location(config)),
        },
    );
}
