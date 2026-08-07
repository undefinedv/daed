#!/bin/sh
#
# Build every package of the set for one format, from trees already laid out by
# stage.sh. Keeps the per-package metadata in one place instead of spread across
# workflow steps, and gives the same entry point on the runner (ipk) and inside
# Alpine (apk).
#
# Usage: build-all.sh <ipk|apk> <pkgarch> <version> <outdir>
#
# Expects, relative to the current directory:
#   stage/daed  stage/luci-app  stage/luci-i18n
#
# POSIX sh: also runs inside Alpine's busybox ash.
#
set -eu

[ $# -eq 4 ] || { echo "usage: build-all.sh <ipk|apk> <pkgarch> <version> <outdir>" >&2; exit 1; }

FORMAT=$1
ARCH=$2
VERSION=$3
OUT=$4

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUILD=$SELF_DIR/build-package.sh

# The LuCI app carries its own version, independent of the daed build date.
LUCI_VERSION=1.4-r1

# Mirrors the DEPENDS of the OpenWrt daed package, minus the entries that only
# make sense when building through the SDK ($(GO_ARCH_DEPENDS), the
# @KERNEL_XDP_SOCKETS config symbol, and the vmlinux-btf alternative — this
# build assumes the kernel carries its own BTF).
"$BUILD" --root stage/daed --name daed --version "$VERSION" --arch "$ARCH" \
	--depends 'ca-bundle kmod-sched-core kmod-sched-bpf kmod-veth v2ray-geoip v2ray-geosite' \
	--description 'daed is a backend of dae, provides a method to bundle arbitrary frontend, dae and geodata into one binary. This build additionally carries hysteria2 salamander obfuscation.' \
	--conffiles '/etc/config/daed' \
	--format "$FORMAT" --out "$OUT"

# Architecture-independent; build-package.sh maps `all` to apk's `noarch`.
# Depends copied from the reference package's control file.
#
# --postinst-pkg is not optional here. Installing the app registers its menu
# entry, but LuCI hides any entry whose rpcd ACL is not loaded, and rpcd only
# reads /usr/share/rpcd/acl.d at start. Without this the app is invisible in the
# web UI until the router reboots — the exact symptom seen on a live install.
# default_postinst's own `rm -f /tmp/luci-indexcache` does not help either: it
# predates the hashed /tmp/luci-indexcache.<hash>.json names.
"$BUILD" --root stage/luci-app --name luci-app-daed --version "$LUCI_VERSION" --arch all \
	--depends 'libc daed zoneinfo-asia luci-compat luci-lua-runtime' \
	--description 'LuCI Support for DAED' \
	--postinst-pkg "$SELF_DIR/files/luci-postinst-pkg" \
	--section luci --format "$FORMAT" --out "$OUT"

"$BUILD" --root stage/luci-i18n --name luci-i18n-daed-zh-cn --version "$LUCI_VERSION" --arch all \
	--depends 'libc luci-app-daed' \
	--description 'Translation for luci-app-daed - 简体中文 (Simplified Chinese)' \
	--section luci --format "$FORMAT" --out "$OUT"
