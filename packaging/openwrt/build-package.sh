#!/bin/sh
#
# Turn a prepared file tree into an OpenWrt package.
#
# Deliberately generic: the same code path packages daed, luci-app-daed and
# luci-i18n-daed-zh-cn. Use stage.sh to build the trees.
#
# Two output formats, because OpenWrt changed package managers mid-stream:
#   ipk  opkg,  OpenWrt <= 24.10  (tar.gz of debian-binary + control + data)
#   apk  apk-tools 3, OpenWrt >= 25.12  (ADB format; only `apk mkpkg` writes it)
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
Usage: build-package.sh --root <dir> --name <pkg> --version <ver>
                        --arch <pkgarch> --format ipk|apk --out <dir>
                        [--depends "<a b c>"] [--description <text>]
                        [--conffiles "</p/a /p/b>"]

  --root     file tree to package, laid out as it will appear on the device
  --name     package name
  --version  package version, must satisfy apk's grammar: digits and dots,
             then -r<n>, e.g. 2026.08.08-r1
  --arch     OpenWrt package architecture, NOT the Go arch. Determines which
             devices will accept the package:
               arm_cortex-a9   bcm53xx / Phicomm K3 and other Cortex-A9
               aarch64_generic 64-bit ARM
               x86_64          64-bit x86
               all             architecture-independent (becomes apk's noarch)
  --format   ipk (opkg, <= 24.10) or apk (apk-tools 3, >= 25.12)
  --out      directory to write the package into
  --section  package section (default: net; LuCI packages use luci)

Environment:
  IPKG_BUILD  path to OpenWrt's scripts/ipkg-build (ipk format only)
EOF
	exit 1
}

ROOT=
NAME=
VERSION=
ARCH=
FORMAT=
OUT=
DEPENDS=
DESCRIPTION=
CONFFILES=
SECTION=net

while [ $# -gt 0 ]; do
	case "$1" in
		--root)        ROOT=${2:?}; shift 2 ;;
		--name)        NAME=${2:?}; shift 2 ;;
		--version)     VERSION=${2:?}; shift 2 ;;
		--arch)        ARCH=${2:?}; shift 2 ;;
		--format)      FORMAT=${2:?}; shift 2 ;;
		--out)         OUT=${2:?}; shift 2 ;;
		--depends)     DEPENDS=${2:-}; shift 2 ;;
		--description) DESCRIPTION=${2:-}; shift 2 ;;
		--conffiles)   CONFFILES=${2:-}; shift 2 ;;
		--section)     SECTION=${2:?}; shift 2 ;;
		-h|--help) usage ;;
		*) echo "build-package.sh: unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "$ROOT" ] && [ -n "$NAME" ] && [ -n "$VERSION" ] && [ -n "$ARCH" ] &&
	[ -n "$FORMAT" ] && [ -n "$OUT" ] || usage
[ -d "$ROOT" ] || { echo "build-package.sh: no such tree: $ROOT" >&2; exit 1; }

: "${DESCRIPTION:=$NAME}"

MAINTAINER='https://github.com/undefinedv/daed'
URL='https://github.com/daeuniverse/daed'
LICENSE='AGPL-3.0-only MIT'

mkdir -p "$OUT"
OUT=$(CDPATH='' cd -- "$OUT" && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Work on a copy: the caller may reuse the tree for the other format, and the
# ipk path drops a CONTROL/ directory into it.
TREE=$WORK/root
mkdir -p "$TREE"
(cd "$ROOT" && tar cf - .) | (cd "$TREE" && tar xf -)

# --- maintainer scripts ----------------------------------------------------
# Same bodies OpenWrt generates in include/package-pack.mk: delegate to
# default_postinst / default_prerm so init scripts get enabled and
# /etc/uci-defaults entries run, identically under opkg and apk.
cat > "$WORK/postinst" <<EOF
#!/bin/sh
[ -s "\${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "\${IPKG_INSTROOT}/lib/functions.sh"
export root="\${IPKG_INSTROOT}"
export pkgname="$NAME"
default_postinst
EOF

cat > "$WORK/prerm" <<EOF
#!/bin/sh
[ -s "\${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "\${IPKG_INSTROOT}/lib/functions.sh"
export root="\${IPKG_INSTROOT}"
export pkgname="$NAME"
default_prerm
EOF

chmod 0755 "$WORK/postinst" "$WORK/prerm"

# Archive as root:root. Without fakeroot (or real root) this is a no-op and the
# package would carry the build user's uid, so say so rather than failing.
if ! chown -R 0:0 "$TREE" "$WORK/postinst" "$WORK/prerm" 2>/dev/null; then
	echo "build-package.sh: warning: cannot chown to 0:0 — run under fakeroot or as root" >&2
fi

case "$FORMAT" in
ipk)
	IPKG_BUILD=${IPKG_BUILD:-ipkg-build}
	command -v "$IPKG_BUILD" >/dev/null 2>&1 || [ -x "$IPKG_BUILD" ] || {
		echo "build-package.sh: ipkg-build not found (set IPKG_BUILD)" >&2
		exit 1
	}

	install -d -m 0755 "$TREE/CONTROL"
	{
		echo "Package: $NAME"
		echo "Version: $VERSION"
		[ -z "$DEPENDS" ] || echo "Depends: $(echo "$DEPENDS" | sed 's/  */, /g')"
		echo "Section: $SECTION"
		echo "Architecture: $ARCH"
		echo "Installed-Size: 0"
		echo "Maintainer: $MAINTAINER"
		echo "License: $LICENSE"
		echo "Source: $URL"
		echo "Description: $DESCRIPTION"
	} > "$TREE/CONTROL/control"

	# ipkg-build resolves each conffile with `find`, so only name paths the
	# package actually ships. opkg never deletes files it does not own, so a
	# runtime-created file such as /etc/daed/wing.db survives upgrades whether
	# or not it is listed.
	if [ -n "$CONFFILES" ]; then
		for cf in $CONFFILES; do echo "$cf"; done > "$TREE/CONTROL/conffiles"
		chmod 0644 "$TREE/CONTROL/conffiles"
	fi

	cp "$WORK/postinst" "$TREE/CONTROL/postinst"
	cp "$WORK/prerm" "$TREE/CONTROL/prerm"
	chmod 0644 "$TREE/CONTROL/control"
	chown -R 0:0 "$TREE/CONTROL" 2>/dev/null || true

	# ipkg-build names the result ${pkg}_${version}_${arch}.ipk itself.
	"$IPKG_BUILD" "$TREE" "$OUT"
	;;

apk)
	command -v apk >/dev/null 2>&1 || {
		echo "build-package.sh: apk not found — the apk format needs apk-tools >= 3" >&2
		exit 1
	}

	# apk spells architecture-independent "noarch", as package-pack.mk does.
	APK_ARCH=$ARCH
	[ "$ARCH" = "all" ] && APK_ARCH=noarch

	# post-upgrade is a separate hook in apk; opkg reuses postinst for both.
	{ printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'; sed '/^[[:space:]]*#!/d' "$WORK/postinst"; } > "$WORK/post-upgrade"
	chmod 0755 "$WORK/post-upgrade"
	chown 0:0 "$WORK/post-upgrade" 2>/dev/null || true

	set -- \
		--info "name:$NAME" \
		--info "version:$VERSION" \
		--info "description:$DESCRIPTION" \
		--info "arch:$APK_ARCH" \
		--info "license:$LICENSE" \
		--info "origin:$NAME" \
		--info "url:$URL" \
		--info "maintainer:$MAINTAINER" \
		--script "post-install:$WORK/postinst" \
		--script "post-upgrade:$WORK/post-upgrade" \
		--script "pre-deinstall:$WORK/prerm" \
		--files "$TREE" \
		--output "$OUT/${NAME}-${VERSION}-${APK_ARCH}.apk"
	[ -z "$DEPENDS" ] || set -- --info "depends:$DEPENDS" "$@"

	apk mkpkg "$@"
	echo "Packaged contents of $ROOT into $OUT/${NAME}-${VERSION}-${APK_ARCH}.apk"
	;;

*)
	echo "build-package.sh: unknown format: $FORMAT (want ipk or apk)" >&2
	exit 1
	;;
esac
