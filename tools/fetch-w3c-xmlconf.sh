#!/bin/sh
# Fetches and verifies the pinned W3C XML Test Suite archive.

set -eu

archive_name=xmlts20130923.tar.gz
source_url=https://www.w3.org/XML/Test/xmlts20130923.tar.gz
expected_sha256=9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
data_dir=${1:-$root_dir/data/conformance}
cache_dir=$data_dir/.cache
archive=$cache_dir/$archive_name
destination=$data_dir/xmlts-2013-09-23
download=
listing=
staging=

cleanup() {
    [ -z "$download" ] || rm -f -- "$download"
    [ -z "$listing" ] || rm -f -- "$listing"
    [ -z "$staging" ] || rm -rf -- "$staging"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$cache_dir"
if [ -L "$cache_dir" ] || [ -L "$archive" ]; then
    echo "fetch-w3c-xmlconf: cache paths must not be symbolic links" >&2
    exit 1
fi
if [ ! -f "$archive" ]; then
    download=$(mktemp "$cache_dir/.xmlts-download.XXXXXX")
    curl -fL --retry 3 -o "$download" "$source_url"
    printf '%s  %s\n' "$expected_sha256" "$download" | sha256sum -c - >/dev/null
    mv -T -- "$download" "$archive"
    download=
fi
printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum -c - >/dev/null

listing=$(mktemp "$cache_dir/.xmlts-listing.XXXXXX")
tar -tzf "$archive" >"$listing"
if awk '
    BEGIN { entries = 0 }
    { entries += 1 }
    /^\// { bad = 1 }
    /(^|\/)\.\.($|\/)/ { bad = 1 }
    !/^xmlconf\// { bad = 1 }
    END { exit bad || entries == 0 }
' "$listing"; then
    :
else
    echo "fetch-w3c-xmlconf: archive contains an unsafe path" >&2
    exit 1
fi
rm -f -- "$listing"
listing=

if [ -L "$destination" ]; then
    echo "fetch-w3c-xmlconf: destination must not be a symbolic link: $destination" >&2
    exit 1
fi

staging=$(mktemp -d "$data_dir/.xmlts-2013-09-23.XXXXXX")
tar -xzf "$archive" -C "$staging"
if [ ! -f "$staging/xmlconf/xmlconf.xml" ] ||
    [ -L "$staging/xmlconf/xmlconf.xml" ] ||
    [ ! -f "$staging/xmlconf/testcases.dtd" ] ||
    [ -L "$staging/xmlconf/testcases.dtd" ]; then
    echo "fetch-w3c-xmlconf: extracted suite is incomplete" >&2
    exit 1
fi
if [ -e "$destination" ]; then
    if diff -qr --no-dereference "$staging" "$destination" >/dev/null; then
        printf '%s\n' "$destination"
        exit 0
    fi
    echo "fetch-w3c-xmlconf: destination does not match the pinned archive: $destination" >&2
    exit 1
fi
mv -T -- "$staging" "$destination"
staging=
printf '%s\n' "$destination"
