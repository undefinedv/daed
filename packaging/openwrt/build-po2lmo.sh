#!/bin/sh
#
# Build LuCI's po2lmo, which compiles a .po into the binary .lmo catalogue
# LuCI loads at runtime. Needed to produce luci-i18n-daed-zh-cn without
# dragging in the whole OpenWrt/LuCI build tree.
#
# Follows modules/luci-base/src/Makefile:
#   contrib/lemon        <- cc contrib/lemon.c
#   lib/plural_formula.c <- ./contrib/lemon -q lib/plural_formula.y
#   po2lmo               <- po2lmo.o lib/lmo.o lib/plural_formula.o
#
# Note plural_formula.y is Lemon (SQLite's generator), not yacc/bison — feeding
# it to bison fails on the very first directive.
#
# lemon reads its lempar.c template from beside the binary, so both files have
# to land in the same directory.
#
set -eu

REF=${LUCI_REF:-master}
OUT=${1:-./po2lmo}

command -v cc >/dev/null 2>&1 || { echo "build-po2lmo.sh: no C compiler" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BASE="https://raw.githubusercontent.com/openwrt/luci/$REF/modules/luci-base/src"

mkdir -p "$WORK/lib" "$WORK/contrib"
for f in po2lmo.c lib/lmo.c lib/lmo.h lib/plural_formula.y contrib/lemon.c contrib/lempar.c; do
	curl -fsSL -o "$WORK/$f" "$BASE/$f"
done

cc -std=gnu17 -w -o "$WORK/contrib/lemon" "$WORK/contrib/lemon.c"
(cd "$WORK/lib" && ../contrib/lemon -q plural_formula.y)
cc -O2 -w -I"$WORK/lib" -o "$WORK/po2lmo" \
	"$WORK/po2lmo.c" "$WORK/lib/lmo.c" "$WORK/lib/plural_formula.c"

mkdir -p "$(dirname "$OUT")"
cp "$WORK/po2lmo" "$OUT"
chmod 0755 "$OUT"
echo "built $OUT (luci@$REF)"
