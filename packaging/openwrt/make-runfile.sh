#!/bin/sh
#
# Wrap OpenWrt packages into a makeself self-extracting installer (.run),
# the shape luci-app-daed-runfiles distributes: the archive carries the
# package files plus an install.sh that hands them to the package manager.
#
# Extracting a reference .run shows the whole contract:
#   payload/  daed_<ver>_<arch>.ipk, ...other .ipk...
#             install.sh  ->  opkg update; opkg install *.ipk
# makeself runs install.sh from a temp dir after unpacking, then cleans up.
#
# Dependencies not shipped inside the archive (kmod-sched-core, kmod-sched-bpf,
# ...) are resolved over the network by that `update` line, so the router needs
# a working feed at install time.
#
set -eu

usage() {
	cat >&2 <<'EOF'
Usage: make-runfile.sh --kind ipk|apk --label <text> --out <file.run> <package>...

  --kind   which package manager install.sh should call:
             ipk  opkg,  OpenWrt <= 24.10
             apk  apk,   OpenWrt >= 25.12
  --label  description makeself prints while extracting
  --out    path of the .run to write
  <package>...  package files to place in the archive
EOF
	exit 1
}

KIND=
LABEL=
OUT=

while [ $# -gt 0 ]; do
	case "$1" in
		--kind)  KIND=${2:?}; shift 2 ;;
		--label) LABEL=${2:?}; shift 2 ;;
		--out)   OUT=${2:?}; shift 2 ;;
		-h|--help) usage ;;
		--) shift; break ;;
		-*) echo "make-runfile.sh: unknown argument: $1" >&2; usage ;;
		*) break ;;
	esac
done

[ -n "$KIND" ] && [ -n "$LABEL" ] && [ -n "$OUT" ] && [ $# -gt 0 ] || usage

MAKESELF=$(command -v makeself || command -v makeself.sh || true)
[ -n "$MAKESELF" ] || { echo "make-runfile.sh: makeself not found" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PAYLOAD=$WORK/payload
mkdir -p "$PAYLOAD"

for pkg in "$@"; do
	[ -f "$pkg" ] || { echo "make-runfile.sh: no such package: $pkg" >&2; exit 1; }
	cp "$pkg" "$PAYLOAD/"
done

case "$KIND" in
ipk)
	cat > "$PAYLOAD/install.sh" <<'EOF'
#!/bin/sh
set -e
opkg update
opkg install ./*.ipk
EOF
	;;
apk)
	# --allow-untrusted: these packages are not signed by the router's keyring.
	cat > "$PAYLOAD/install.sh" <<'EOF'
#!/bin/sh
set -e
apk update
apk add --allow-untrusted ./*.apk
EOF
	;;
*)
	echo "make-runfile.sh: unknown kind: $KIND (want ipk or apk)" >&2
	exit 1
	;;
esac
chmod 0755 "$PAYLOAD/install.sh"

mkdir -p "$(dirname "$OUT")"

# --nox11/--nowait keep it non-interactive on a router with no X and no tty
# games; gzip because that is what busybox on OpenWrt can always decompress.
"$MAKESELF" --gzip --nox11 --nowait \
	"$PAYLOAD" "$OUT" "$LABEL" ./install.sh

echo "Packaged $# package(s) into $OUT"
