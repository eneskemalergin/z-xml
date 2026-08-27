//! Shared XML character, name, namespace, whitespace, and predefined-entity rules.

const std = @import("std");

pub const XML_NAMESPACE_URI = "http://www.w3.org/XML/1998/namespace";
pub const XMLNS_NAMESPACE_URI = "http://www.w3.org/2000/xmlns/";

pub const Version = enum {
    xml10,
    xml11,
};

pub fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

pub fn allWhitespace(bytes: []const u8) bool {
    for (bytes) |byte| if (!isWhitespace(byte)) return false;
    return true;
}

pub fn isNameStart(codepoint: u32) bool {
    return codepoint == ':' or
        (codepoint >= 'A' and codepoint <= 'Z') or
        codepoint == '_' or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0xc0 and codepoint <= 0xd6) or
        (codepoint >= 0xd8 and codepoint <= 0xf6) or
        (codepoint >= 0xf8 and codepoint <= 0x2ff) or
        (codepoint >= 0x370 and codepoint <= 0x37d) or
        (codepoint >= 0x37f and codepoint <= 0x1fff) or
        (codepoint >= 0x200c and codepoint <= 0x200d) or
        (codepoint >= 0x2070 and codepoint <= 0x218f) or
        (codepoint >= 0x2c00 and codepoint <= 0x2fef) or
        (codepoint >= 0x3001 and codepoint <= 0xd7ff) or
        (codepoint >= 0xf900 and codepoint <= 0xfdcf) or
        (codepoint >= 0xfdf0 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0xeffff);
}

pub fn isNameChar(codepoint: u32) bool {
    return isNameStart(codepoint) or codepoint == '-' or codepoint == '.' or
        (codepoint >= '0' and codepoint <= '9') or codepoint == 0xb7 or
        (codepoint >= 0x300 and codepoint <= 0x36f) or
        (codepoint >= 0x203f and codepoint <= 0x2040);
}

pub fn isChar(codepoint: u32, version: Version) bool {
    return switch (version) {
        .xml10 => codepoint == 0x9 or codepoint == 0xa or codepoint == 0xd or
            (codepoint >= 0x20 and codepoint <= 0xd7ff) or
            (codepoint >= 0xe000 and codepoint <= 0xfffd) or
            (codepoint >= 0x10000 and codepoint <= 0x10ffff),
        .xml11 => (codepoint >= 0x1 and codepoint <= 0xd7ff) or
            (codepoint >= 0xe000 and codepoint <= 0xfffd) or
            (codepoint >= 0x10000 and codepoint <= 0x10ffff),
    };
}

pub fn isXml11RestrictedChar(codepoint: u32) bool {
    return (codepoint >= 0x1 and codepoint <= 0x8) or
        (codepoint >= 0xb and codepoint <= 0xc) or
        (codepoint >= 0xe and codepoint <= 0x1f) or
        (codepoint >= 0x7f and codepoint <= 0x84) or
        (codepoint >= 0x86 and codepoint <= 0x9f);
}

pub fn isLiteralChar(codepoint: u32, version: Version) bool {
    return isChar(codepoint, version) and
        (version == .xml10 or !isXml11RestrictedChar(codepoint));
}

pub fn predefinedEntity(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "amp")) return "&";
    if (std.mem.eql(u8, name, "lt")) return "<";
    if (std.mem.eql(u8, name, "gt")) return ">";
    if (std.mem.eql(u8, name, "apos")) return "'";
    if (std.mem.eql(u8, name, "quot")) return "\"";
    return null;
}
