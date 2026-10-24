#!/bin/sh
# tests/native/run.sh <image> [platform]   e.g. ubuntu:24.04, rockylinux:9, alpine:3.20
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
img=$1; plat=${2:-}
echo "== native $img ${plat:-native}"
docker run --rm ${plat:+--platform "$plat"} -v "$root:/src:ro" "$img" sh /src/tests/native/inner.sh "$img"
