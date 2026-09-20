#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temp=$(mktemp -d /tmp/point-s3-tests.XXXXXX)
trap 'rm -rf "$temp"' EXIT
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I "$root/src" \
    "$root/src/protocol.c" "$root/test/protocol_test.c" -o "$temp/protocol"
"$temp/protocol"
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I "$root/src" \
    "$root/src/motor_pattern.c" "$root/test/motor_pattern_test.c" -o "$temp/motor"
"$temp/motor"
