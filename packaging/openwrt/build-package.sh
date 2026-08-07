#!/bin/sh
#
# Wrap a prebuilt, fully-static daed binary into an OpenWrt package.
#
# The binaries produced by .github/workflows/build-salamander.yml are built with
# CGO_ENABLED=0, so they carry no libc dependency and need no cross toolchain to
# package — the archive is just metadata around a file tree. That is why this
# repackages rather than rebuilding through the OpenWrt SDK.
#
# Two output formats, because OpenWrt changed package managers mid-stream:
#   ipk  opkg,  OpenWrt <= 24.10  (tar.gz of debian-binary + control + data)
#   apk  apk-tools 3, OpenWrt >= 25.12  (ADB format; only `apk mkpkg` can write it)
#
# The ipk path shells out to OpenWrt's own scripts/ipkg-build (point IPKG_BUILD
# at it); the apk path shells out to `apk mkpkg` and therefore has to run
# somewhere that ships apk-tools >= 3 (alpine:edge does).
#
# Run under fakeroot, or as root, so the archived files end up owned by 0:0.
#
# POSIX sh on purpose: the apk path runs inside Alpine's busybox ash.
#
set -eu

usage() {
	cat >&2 <<'EOF'
Usage: build-package.sh --bin <file> --arch <pkgarch> --version <ver>
                        --format ipk|apk --out <dir>

  --bin      prebuilt daed binary (e.g. daed-linux-armv7)
  --arch     OpenWrt package architecture, NOT the Go arch. Determines which
             devices will accept the package:
               arm_cortex-a9   bcm53xx / Phicomm K3 and other Cortex-A9
               aarch64_generic 64-bit ARM
               x86_64          64-bit x86
  --version  package version, must satisfy apk's grammar: digits and dots,
             then -r<n>, e.g. 2026.08.08-r1
  --format   ipk (opkg, <= 24.10) or apk (apk-tools 3, >= 25.12)
  --out      directory to write the package into

Environment:
  IPKG_BUILD  path to OpenWrt's scripts/ipkg-build (ipk format only)
EOF
	exit 1
}

BIN=
ARCH=
VERSION=
FORMAT=
OUT=

while [ $# -gt 0 ]; do
	case "$1" in
		--bin)     BIN=${2:?}; shift 2 ;;
		--arch)    ARCH=${2:?}; shift 2 ;;
		--version) VERSION=${2:?}; shift 2 ;;
		--format)  FORMAT=${2:?}; shift 2 ;;
		--out)     OUT=${2:?}; shift 2 ;;
		-h|--help) usage ;;
		*) echo "build-package.sh: unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$BIN" ] && [ -n "$ARCH" ] && [ -n "$VERSION" ] && [ -n "$FORMAT" ] && [ -n "$OUT" ] || usage
[ -f "$BIN" ] || { echo "build-package.sh: no such binary: $BIN" >&2; exit 1; }

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FILES_DIR=$SELF_DIR/files

# Mirrors the DEPENDS of the OpenWrt daed package, minus the entries that only
# make sense when building through the SDK ($(GO_ARCH_DEPENDS), the
# @KERNEL_XDP_SOCKETS config symbol, and the vmlinux-btf alternative — this
# build assumes the kernel carries its own BTF).
DEPENDS='ca-bundle kmod-sched-core kmod-sched-bpf kmod-veth v2ray-geoip v2ray-geosite'
DESCRIPTION='daed is a backend of dae, provides a method to bundle arbitrary frontend, dae and geodata into one binary. This build additionally carries hysteria2 salamander obfuscation.'
MAINTAINER='https://github.com/undefinedv/daed'
URL='https://github.com/daeuniverse/daed'
LICENSE='AGPL-3.0-only MIT'

mkdir -p "$OUT"
OUT=$(CDPATH='' cd -- "$OUT" && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT=$WORK/root

# --- payload ---------------------------------------------------------------
# /etc/daed is created empty: daed writes wing.db there on first run, and the
# init script passes --config /etc/daed/.
install -d -m 0755 "$ROOT/usr/bin" "$ROOT/etc/init.d" "$ROOT/etc/config" "$ROOT/etc/daed"
install -m 0755 "$BIN" "$ROOT/usr/bin/daed"
install -m 0755 "$FILES_DIR/daed.init" "$ROOT/etc/init.d/daed"
install -m 0644 "$FILES_DIR/daed.config" "$ROOT/etc/config/daed"

# --- maintainer scripts ----------------------------------------------------
# Same bodies OpenWrt generates in include/package-pack.mk: delegate to
# default_postinst / default_prerm so the init script gets enabled and
# /etc/uci-defaults entries run, on both opkg and apk.
cat > "$WORK/postinst" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
export pkgname="daed"
default_postinst
EOF

cat > "$WORK/prerm" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
export pkgname="daed"
default_prerm
EOF

chmod 0755 "$WORK/postinst" "$WORK/prerm"

# Archive as root:root. Without fakeroot (or real root) this is a no-op and the
# package would carry the build user's uid, so say so rather than failing.
if ! chown -R 0:0 "$ROOT" "$WORK/postinst" "$WORK/prerm" 2>/dev/null; then
	echo "build-package.sh: warning: cannot chown to 0:0 — run under fakeroot or as root" >&2
fi

case "$FORMAT" in
ipk)
	IPKG_BUILD=${IPKG_BUILD:-ipkg-build}
	command -v "$IPKG_BUILD" >/dev/null 2>&1 || [ -x "$IPKG_BUILD" ] || {
		echo "build-package.sh: ipkg-build not found (set IPKG_BUILD)" >&2
		exit 1
	}

	# Only /etc/config/daed is listed. ipkg-build resolves each conffile with
	# `find`, so naming a path the package does not ship (upstream also lists
	# /etc/daed/wing.db) risks tripping its `set -e`. opkg never deletes files
	# it does not own anyway, so wing.db survives upgrades regardless.
	install -d -m 0755 "$ROOT/CONTROL"
	cat > "$ROOT/CONTROL/control" <<EOF
Package: daed
Version: $VERSION
Depends: $(echo "$DEPENDS" | sed 's/ /, /g')
Section: net
Category: Network
Architecture: $ARCH
Installed-Size: 0
Maintainer: $MAINTAINER
License: $LICENSE
Source: $URL
Description: $DESCRIPTION
EOF
	printf '/etc/config/daed\n' > "$ROOT/CONTROL/conffiles"
	cp "$WORK/postinst" "$ROOT/CONTROL/postinst"
	cp "$WORK/prerm" "$ROOT/CONTROL/prerm"
	chmod 0644 "$ROOT/CONTROL/control" "$ROOT/CONTROL/conffiles"
	chown -R 0:0 "$ROOT/CONTROL" 2>/dev/null || true

	# ipkg-build names the result ${pkg}_${version}_${arch}.ipk itself.
	"$IPKG_BUILD" "$ROOT" "$OUT"
	;;

apk)
	command -v apk >/dev/null 2>&1 || {
		echo "build-package.sh: apk not found — the apk format needs apk-tools >= 3" >&2
		exit 1
	}

	# post-upgrade is a separate hook in apk; opkg reuses postinst for both.
	{ printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'; sed '/^[[:space:]]*#!/d' "$WORK/postinst"; } > "$WORK/post-upgrade"
	chmod 0755 "$WORK/post-upgrade"
	chown 0:0 "$WORK/post-upgrade" 2>/dev/null || true

	apk mkpkg \
		--info "name:daed" \
		--info "version:$VERSION" \
		--info "description:$DESCRIPTION" \
		--info "arch:$ARCH" \
		--info "license:$LICENSE" \
		--info "origin:daed" \
		--info "url:$URL" \
		--info "maintainer:$MAINTAINER" \
		--info "depends:$DEPENDS" \
		--script "post-install:$WORK/postinst" \
		--script "post-upgrade:$WORK/post-upgrade" \
		--script "pre-deinstall:$WORK/prerm" \
		--files "$ROOT" \
		--output "$OUT/daed-${VERSION}-${ARCH}.apk"
	echo "Packaged contents of $ROOT into $OUT/daed-${VERSION}-${ARCH}.apk"
	;;

*)
	echo "build-package.sh: unknown format: $FORMAT (want ipk or apk)" >&2
	exit 1
	;;
esac
