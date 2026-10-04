#!/usr/bin/env bash
# Writes the patches BspatchTests reads. valid.patch comes from bsdiff 4.3, the reference, taken from the PATH: macOS
# ships no /usr/bin/bsdiff, and `brew install bsdiff` puts Homebrew's at /opt/homebrew/bin/bsdiff. The hostile patches
# carry hand-made control blocks.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v bsdiff > /dev/null; then
  echo "bsdiff is not on the PATH: install bsdiff 4.3 with 'brew install bsdiff'" >&2
  exit 1
fi

# One bsdiff offset: eight bytes little-endian, the sign in the top bit of the last.
write_offset() {
  local value=$1 sign=0 index byte
  if [ "$value" -lt 0 ]; then
    value=$((-value))
    sign=128
  fi
  for index in 0 1 2 3 4 5 6 7; do
    byte=$(((value >> (8 * index)) & 255))
    if [ "$index" -eq 7 ]; then byte=$((byte | sign)); fi
    printf "\\$(printf '%03o' "$byte")"
  done
}

# A BSDIFF40 patch: the new size, the control triples, then the diff block's and the extra block's length in zero bytes.
write_patch() {
  local new_size=$1 diff_bytes=$2 extra_bytes=$3 control=() value
  shift 3
  for value in "$@"; do control+=("$(write_offset "$value" | xxd -p)"); done
  local control_block diff_block extra_block
  control_block=$(printf '%s' "${control[@]}" | xxd -r -p | bzip2 -9 -c | xxd -p | tr -d '\n')
  diff_block=$(dd if=/dev/zero bs=1 count="$diff_bytes" 2>/dev/null | bzip2 -9 -c | xxd -p | tr -d '\n')
  extra_block=$(dd if=/dev/zero bs=1 count="$extra_bytes" 2>/dev/null | bzip2 -9 -c | xxd -p | tr -d '\n')
  {
    printf 'BSDIFF40'
    write_offset $((${#control_block} / 2))
    write_offset $((${#diff_block} / 2))
    write_offset "$new_size"
    printf '%s%s%s' "$control_block" "$diff_block" "$extra_block" | xxd -r -p
  }
}

for line in $(seq 1 200); do
  printf 'export const value%d = "release one, line %d";\n' "$line" "$line"
done > old.bin
for line in $(seq 1 200); do
  if [ $((line % 17)) -eq 0 ]; then release=two; else release=one; fi
  printf 'export const value%d = "release %s, line %d";\n' "$line" "$release" "$line"
done > new.bin
printf 'export const isAdded = true;\n' >> new.bin
bsdiff old.bin new.bin valid.patch

write_patch 16 32 0 32 0 0 > diff-past-new-file.patch
write_patch 16 0 32 0 32 0 > extra-past-new-file.patch
write_patch 32 32 0 0 0 -1000000000 32 0 0 > seek-before-old-file.patch
write_patch 32 32 0 0 0 1000000000 32 0 0 > seek-past-old-file.patch
