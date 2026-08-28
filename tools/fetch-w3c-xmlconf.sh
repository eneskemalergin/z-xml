#!/bin/sh
# Fetches and verifies the pinned W3C XML Test Suite archive.

set -eu

archive_name=xmlts20130923.tar.gz
source_url=https://www.w3.org/XML/Test/xmlts20130923.tar.gz
observed_sha256=9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
data_dir=${1:-$root_dir/data/conformance}
cache_dir=$data_dir/.cache
archive=$cache_dir/$archive_name
destination=$data_dir/xmlts-2013-09-23

if [ -f "$destination/xmlconf/xmlconf.xml" ]; then
    printf '%s\n' "$destination"
    exit 0
fi
if [ -e "$destination" ]; then
    echo "fetch-w3c-xmlconf: incomplete destination exists: $destination" >&2
    exit 1
fi

mkdir -p "$cache_dir"
if [ ! -f "$archive" ]; then
    curl -fL --retry 3 -o "$archive.tmp" "$source_url"
    mv "$archive.tmp" "$archive"
fi
printf '%s  %s\n' "$observed_sha256" "$archive" | sha256sum -c -

if tar -tzf "$archive" | awk '
    /^\// { bad = 1 }
    /(^|\/)\.\.($|\/)/ { bad = 1 }
    END { exit bad }
'; then
    :
else
    echo "fetch-w3c-xmlconf: archive contains an unsafe path" >&2
    exit 1
fi

staging=$(mktemp -d "$data_dir/.xmlts-2013-09-23.XXXXXX")
tar -xzf "$archive" -C "$staging"
test -f "$staging/xmlconf/xmlconf.xml"
mv "$staging" "$destination"
printf '%s\n' "$destination"
