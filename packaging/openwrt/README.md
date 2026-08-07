# OpenWrt packages for the salamander build

Wraps the binaries from `.github/workflows/build-salamander.yml` into installable
OpenWrt packages — the same payload `luci-app-daed-runfiles` ships (procd init
script, uci config, the `daed` binary), but built by repackaging rather than by
compiling through the OpenWrt SDK.

That shortcut is sound because the binaries are `CGO_ENABLED=0` fully-static:
they have no libc dependency, so no target toolchain is involved and the archive
is just metadata around a file tree.

## What gets built

| Go arch | OpenWrt `Architecture` | Device |
| --- | --- | --- |
| armv7 | `arm_cortex-a9` | bcm53xx — Phicomm K3 |
| arm64 | `aarch64_generic` | 64-bit ARM |
| amd64 | `x86_64` | 64-bit x86 |

Two formats per architecture, because OpenWrt changed package managers:

- `daed_<version>_<arch>.ipk` — opkg, OpenWrt **24.10 and earlier**
- `daed-<version>-<arch>.apk` — apk-tools 3, OpenWrt **25.12 and later**

## Installing

```sh
# OpenWrt <= 24.10
opkg install ./daed_2026.08.08-r1_arm_cortex-a9.ipk

# OpenWrt >= 25.12
apk add --allow-untrusted ./daed-2026.08.08-r1-arm_cortex-a9.apk
```

One `Architecture` string is emitted per binary. A device whose arch string
differs but whose CPU is compatible — say `arm_cortex-a7_neon-vfpv4`, which the
armv7 binary runs on fine — will refuse the package until you override the check:

```sh
opkg install --force-architecture ./daed_..._arm_cortex-a9.ipk
apk add --allow-untrusted --force-non-repository ./daed-...-arm_cortex-a9.apk
```

### Dependencies

The packages declare `ca-bundle kmod-sched-core kmod-sched-bpf kmod-veth
v2ray-geoip v2ray-geosite`. The two `kmod-sched-*` packages are what supply the
`NET_SCH_INGRESS` / `NET_CLS_BPF` / `NET_ACT_BPF` modules dae attaches to, and
they must match the running kernel exactly, so install them from the same build
as your firmware.

The kernel itself still has to satisfy dae: **>= 5.17** with BTF. See the notes
at the bottom of `build-salamander.yml`.

### LuCI

`luci-app-daed` is architecture-independent and unmodified by the salamander
patch, so it is not rebuilt here. Install it from the
[luci-app-daed-runfiles](https://github.com/QiuSimons/luci-app-daed) releases —
it depends on the package name `daed`, which these packages provide.

## Building locally

```sh
curl -fsSL -o /tmp/ipkg-build \
  https://raw.githubusercontent.com/openwrt/openwrt/openwrt-24.10/scripts/ipkg-build
chmod +x /tmp/ipkg-build

fakeroot env IPKG_BUILD=/tmp/ipkg-build SOURCE_DATE_EPOCH=0 \
  ./build-package.sh --bin ./daed-linux-armv7 --arch arm_cortex-a9 \
                     --version 2026.08.08-r1 --format ipk --out ./out
```

The apk format needs `apk mkpkg` from apk-tools >= 3, which is why CI runs that
half inside `alpine:edge`:

```sh
docker run --rm -v "$PWD:/w" -w /w alpine:edge \
  ./build-package.sh --bin ./daed-linux-armv7 --arch arm_cortex-a9 \
                     --version 2026.08.08-r1 --format apk --out ./out
```

Run under `fakeroot` (or as root) or the archived files carry your uid instead
of `0:0`; the script warns when it cannot chown.

## Provenance

`files/daed.init` and `files/daed.config` are taken verbatim from the OpenWrt
`daed` package (ImmortalWrt / QiuSimons' `luci-app-daed`), GPL-2.0-only. The
maintainer-script bodies mirror what OpenWrt's `include/package-pack.mk`
generates, so `default_postinst` / `default_prerm` behave identically under both
opkg and apk.
