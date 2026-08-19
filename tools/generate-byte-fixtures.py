#!/usr/bin/env python3
"""Generate and verify XML fixtures whose bytes are awkward to review as text."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def fixture_bytes() -> dict[str, bytes]:
    utf16_document = (
        '<?xml version="1.0" encoding="UTF-16"?><root>\u03bb\U0001f642</root>'
    )
    utf16le_document = (
        '<?xml version="1.0" encoding="UTF-16LE"?><root>\u03bb\U0001f642</root>'
    )
    utf16be_document = (
        '<?xml version="1.0" encoding="UTF-16BE"?><root>\u03bb\U0001f642</root>'
    )
    utf32_document = '<?xml version="1.0" encoding="UTF-32"?><root>\u03bb</root>'
    utf16_markup = "<\u6839 \u5c5e\u6027='\u503c'>one\r\ntwo\U0001f642</\u6839>"
    return {
        "valid/encoding/utf8-bom.xml": b"\xef\xbb\xbf<root>\xc3\xa9\xf0\x9f\x99\x82</root>",
        "valid/encoding/utf8-codepoint-boundaries.xml": (
            b"<root>\xc2\x80\xe0\xa0\x80\xf0\x90\x80\x80\xf4\x8f\xbf\xbf</root>"
        ),
        "valid/encoding/utf16le-bom.xml": b"\xff\xfe"
        + utf16_document.encode("utf-16-le"),
        "valid/encoding/utf16be-bom.xml": b"\xfe\xff"
        + utf16_document.encode("utf-16-be"),
        "valid/encoding/utf16le-explicit.xml": (
            b"\xff\xfe" + utf16le_document.encode("utf-16-le")
        ),
        "valid/encoding/utf16be-explicit.xml": (
            b"\xfe\xff" + utf16be_document.encode("utf-16-be")
        ),
        "valid/encoding/utf16le-markup.xml": b"\xff\xfe"
        + utf16_markup.encode("utf-16-le"),
        "valid/encoding/utf16be-no-declaration.xml": (
            b"\xfe\xff" + "<root/>".encode("utf-16-be")
        ),
        "valid/encoding/utf32le-bom.xml": (
            b"\xff\xfe\x00\x00" + utf32_document.encode("utf-32-le")
        ),
        "valid/encoding/utf32be-bom.xml": (
            b"\x00\x00\xfe\xff" + utf32_document.encode("utf-32-be")
        ),
        "valid/encoding/iso-8859-1.xml": (
            b'<?xml version="1.0" encoding="ISO-8859-1"?><root>caf\xe9</root>'
        ),
        "valid/encoding/ascii-declared.xml": (
            b'<?xml version="1.0" encoding="US-ASCII"?><root>ASCII</root>'
        ),
        "valid/encoding/cr-line-endings.xml": b"<root>one\rtwo\r</root>\r",
        "valid/encoding/crlf-line-endings.xml": b"<root>one\r\ntwo\r\n</root>\r\n",
        "invalid/encoding/utf8-lone-continuation.xml": b"<root>\x80</root>",
        "invalid/encoding/utf8-overlong.xml": b"<root>\xc0\xaf</root>",
        "invalid/encoding/utf8-truncated.xml": b"<root>\xe2\x82</root>",
        "invalid/encoding/utf8-surrogate.xml": b"<root>\xed\xa0\x80</root>",
        "invalid/encoding/utf8-out-of-range.xml": b"<root>\xf4\x90\x80\x80</root>",
        "invalid/encoding/utf8-invalid-byte.xml": b"<root>\xff</root>",
        "invalid/encoding/literal-null.xml": b"<root>before\x00after</root>",
        "invalid/encoding/literal-control.xml": b"<root>before\x01after</root>",
        "invalid/encoding/utf16le-odd-byte.xml": (
            b"\xff\xfe" + '<root encoding="UTF-16">x</root>'.encode("utf-16-le")[:-1]
        ),
        "invalid/encoding/utf16le-unpaired-high-surrogate.xml": (
            b"\xff\xfe"
            + "<root>".encode("utf-16-le")
            + b"\x00\xd8"
            + "</root>".encode("utf-16-le")
        ),
        "invalid/encoding/utf16be-unpaired-low-surrogate.xml": (
            b"\xfe\xff"
            + "<root>".encode("utf-16-be")
            + b"\xdc\x00"
            + "</root>".encode("utf-16-be")
        ),
        "invalid/encoding/utf16le-missing-signature.xml": utf16_document.encode(
            "utf-16-le"
        ),
        "invalid/encoding/utf16be-missing-signature.xml": utf16_document.encode(
            "utf-16-be"
        ),
        "invalid/encoding/utf16le-declared-be.xml": (
            b"\xff\xfe" + utf16be_document.encode("utf-16-le")
        ),
        "invalid/encoding/utf16be-declared-le.xml": (
            b"\xfe\xff" + utf16le_document.encode("utf-16-be")
        ),
        "invalid/encoding/utf16le-high-surrogate-final.xml": b"\xff\xfe\x00\xd8",
        "invalid/encoding/declared-utf16-but-utf8.xml": (
            b'<?xml version="1.0" encoding="UTF-16"?><root/>'
        ),
        "invalid/encoding/declared-ascii-with-high-byte.xml": (
            b'<?xml version="1.0" encoding="US-ASCII"?><root>\xc3\xa9</root>'
        ),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--fixture-root",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "fixture",
    )
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    fixtures = fixture_bytes()
    mismatches: list[str] = []
    for relative, expected in sorted(fixtures.items()):
        path = args.fixture_root / relative
        if args.check:
            try:
                observed = path.read_bytes()
            except OSError as error:
                mismatches.append(f"{relative}: {error}")
                continue
            if observed != expected:
                mismatches.append(f"{relative}: generated bytes differ")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
    if mismatches:
        print("\n".join(mismatches), file=sys.stderr)
        return 1
    action = "verified" if args.check else "generated"
    print(f"{action} {len(fixtures)} byte fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
