#!/bin/sh
set -eu
# ESP-IDF rejects spaces in project paths. Build a copy, leaving source in the repo.
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=${POINT_FIRMWARE_BUILD_DIR:-/tmp/point-s3-firmware}
pio_bin=${POINT_PLATFORMIO:-pio}
mkdir -p "$build_dir"
rsync -a --exclude .pio --exclude 'sdkconfig.local*' "$source_dir/" "$build_dir/"
exec "$pio_bin" run --project-dir "$build_dir" "$@"
