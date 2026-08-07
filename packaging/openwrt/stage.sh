#!/bin/sh
#
# Lay out the on-device file trees that build-package.sh turns into packages.
#
# Every layout here was read off the reference packages shipped by
# luci-app-daed-runfiles, so an install lands the same paths OpenWrt's own
# luci.mk / GoBinPackage would have produced.
#
# POSIX sh: also runs inside Alpine's busybox ash.
#
set -eu

usage() {
	cat >&2 <<'EOF'
Usage: stage.sh daed       <daed-binary> <outdir>
       stage.sh luci-app   <luci-src-dir> <outdir>
       stage.sh luci-i18n  <luci-src-dir> <po2lmo> <outdir>

  daed       /usr/bin/daed + procd init script + uci config
  luci-app   luasrc/ -> /usr/lib/lua/luci, root/ -> /
  luci-i18n  po/zh_Hans/daed.po compiled to /usr/lib/lua/luci/i18n/daed.zh-cn.lmo
EOF
	exit 1
}

[ $# -ge 3 ] || usage
WHAT=$1
shift

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

case "$WHAT" in
daed)
	BIN=$1
	OUT=$2
	[ -f "$BIN" ] || { echo "stage.sh: no such binary: $BIN" >&2; exit 1; }
	rm -rf "$OUT"
	# /etc/daed is created empty: daed writes wing.db there on first run, and
	# the init script passes --config /etc/daed/.
	install -d -m 0755 "$OUT/usr/bin" "$OUT/etc/init.d" "$OUT/etc/config" "$OUT/etc/daed"
	install -m 0755 "$BIN" "$OUT/usr/bin/daed"
	install -m 0755 "$SELF_DIR/files/daed.init" "$OUT/etc/init.d/daed"
	install -m 0644 "$SELF_DIR/files/daed.config" "$OUT/etc/config/daed"
	;;

luci-app)
	SRC=$1
	OUT=$2
	[ -d "$SRC/luasrc" ] || { echo "stage.sh: not a luci app source dir: $SRC" >&2; exit 1; }
	rm -rf "$OUT"
	install -d -m 0755 "$OUT/usr/lib/lua/luci"
	# luasrc/{controller,model,view} map 1:1 under /usr/lib/lua/luci.
	(cd "$SRC/luasrc" && tar cf - .) | (cd "$OUT/usr/lib/lua/luci" && tar xf -)
	# root/ is copied to / verbatim (init scripts, hotplug hooks, rpcd acl).
	if [ -d "$SRC/root" ]; then
		(cd "$SRC/root" && tar cf - .) | (cd "$OUT" && tar xf -)
	fi
	find "$OUT" -type d -exec chmod 0755 {} +
	find "$OUT" -type f -exec chmod 0644 {} +
	# Anything under etc/init.d or etc/uci-defaults has to stay executable.
	[ -d "$OUT/etc/init.d" ] && chmod 0755 "$OUT/etc/init.d/"* || true
	[ -d "$OUT/etc/uci-defaults" ] && chmod 0755 "$OUT/etc/uci-defaults/"* || true
	[ -d "$OUT/etc/hotplug.d" ] && find "$OUT/etc/hotplug.d" -type f -exec chmod 0755 {} + || true
	;;

luci-i18n)
	[ $# -ge 3 ] || usage
	SRC=$1
	PO2LMO=$2
	OUT=$3
	PO=$SRC/po/zh_Hans/daed.po
	[ -f "$PO" ] || { echo "stage.sh: no translation at $PO" >&2; exit 1; }
	[ -x "$PO2LMO" ] || { echo "stage.sh: po2lmo not executable: $PO2LMO" >&2; exit 1; }
	rm -rf "$OUT"
	install -d -m 0755 "$OUT/usr/lib/lua/luci/i18n" "$OUT/etc/uci-defaults"
	"$PO2LMO" "$PO" "$OUT/usr/lib/lua/luci/i18n/daed.zh-cn.lmo"
	chmod 0644 "$OUT/usr/lib/lua/luci/i18n/daed.zh-cn.lmo"
	# Registers the language with LuCI, same one-liner the reference package
	# ships.
	printf "uci set luci.languages.zh_cn='简体中文 (Simplified Chinese)'; uci commit luci\n" \
		> "$OUT/etc/uci-defaults/luci-i18n-daed-zh-cn"
	chmod 0755 "$OUT/etc/uci-defaults/luci-i18n-daed-zh-cn"
	;;

*)
	usage
	;;
esac

echo "staged $WHAT"
