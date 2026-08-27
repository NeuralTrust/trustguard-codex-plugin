#!/bin/sh
set -eu

printf 'binary=%s\n' "$(basename "$0")"
printf 'args=%s\n' "$*"
while IFS= read -r line; do
    printf 'stdin=%s\n' "$line"
done
