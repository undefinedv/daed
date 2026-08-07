# OpenWrt packages for the salamander build

Turns the binaries from `.github/workflows/build-salamander.yml` into the
artifact `luci-app-daed-runfiles` distributes: a makeself self-extracting
installer carrying every package the router needs, plus an `install.sh` that
hands them to the package manager.

Packages are built by repackaging, not by compiling through the OpenWrt SDK.
That shortcut is sound because the daed binaries are `CGO_ENABLED=0`
fully-static: no libc to link against, so no target toolchain is involved and
the archive is just metadata around a file tree.

## What is inside an installer

| Package | Arch | Source |
| --- | --- | --- |
| `daed` | per-arch | this repository's build |
| `luci-app-daed` | `all` | [wkccd/luci-app-daed-runfiles](https://github.com/wkccd/luci-app-daed-runfiles), pinned commit |
| `luci-i18n-daed-zh-cn` | `all` | same, `.po` compiled with LuCI's `po2lmo` |
| `v2ray-geoip`, `v2ray-geosite` | `all` | OpenWrt's official package feed |

Deliberately **not** bundled:

- `kmod-sched-core`, `kmod-sched-bpf` and friends — these must match the running
  kernel exactly, so a bundled copy would be wrong more often than right.
  `install.sh` runs `opkg update` / `apk update` first and lets the package
  manager pull them, so the router needs a working feed at install time.
- `vmlinux-btf` — only needed by kernels built without `CONFIG_DEBUG_INFO_BTF`.
  The reference archives ship it; a self-compiled kernel with BTF does not need
  it.

## Architectures

| Go arch | OpenWrt `Architecture` | Device |
| --- | --- | --- |
| armv7 | `arm_cortex-a9` | bcm53xx — Phicomm K3 |
| arm64 | `aarch64_generic` | 64-bit ARM |
| amd64 | `x86_64` | 64-bit x86 |

Two installers per architecture, because OpenWrt changed package managers:

- `24-daed-salamander_<version>-<arch>.run` — opkg, OpenWrt **24.10 and earlier**
- `25-daed-salamander_<version>-<arch>.run` — apk-tools 3, OpenWrt **25.12 and later**

The individual `.ipk` / `.apk` files are published alongside, for anyone who
would rather install them by hand.

## Installing

```sh
chmod +x ./24-daed-salamander_2026.08.08-r1-arm_cortex-a9.run
./24-daed-salamander_2026.08.08-r1-arm_cortex-a9.run
```

Two flags worth knowing — neither runs the bundled `install.sh`:

```sh
./….run --list    # show what is inside
./….run --check   # verify the embedded checksum
```

One `Architecture` string is emitted per binary. A device whose arch string
differs but whose CPU is compatible — say `arm_cortex-a7_neon-vfpv4`, which the
armv7 binary runs on fine — will refuse the package until you override the check:

```sh
opkg install --force-architecture ./daed_..._arm_cortex-a9.ipk
apk add --allow-untrusted --force-non-repository ./daed-...-arm_cortex-a9.apk
```

The kernel still has to satisfy dae: **>= 5.17** with BTF. See the notes at the
bottom of `build-salamander.yml`.

## The pieces

| Script | Job |
| --- | --- |
| `stage.sh` | lay out the on-device file trees |
| `build-po2lmo.sh` | build LuCI's `.po` → `.lmo` compiler |
| `build-package.sh` | turn one tree into an `.ipk` or `.apk` |
| `build-all.sh` | run `build-package.sh` over the whole set for one format |
| `make-runfile.sh` | bundle packages into a makeself `.run` |

Staging is separate from packaging because `po2lmo` is compiled against the
build host's libc, while the apk half has to run inside Alpine — so trees are
staged on the host once and packaged from there in both environments.

## Building locally

```sh
curl -fsSL -o /tmp/ipkg-build \
  https://raw.githubusercontent.com/openwrt/openwrt/openwrt-24.10/scripts/ipkg-build
chmod +x /tmp/ipkg-build
./build-po2lmo.sh /tmp/po2lmo
git clone https://github.com/wkccd/luci-app-daed-runfiles.git /tmp/luci-src

./stage.sh daed ./daed-linux-armv7 stage/daed
./stage.sh luci-app  /tmp/luci-src/luci-app-daed stage/luci-app
./stage.sh luci-i18n /tmp/luci-src/luci-app-daed /tmp/po2lmo stage/luci-i18n

fakeroot env IPKG_BUILD=/tmp/ipkg-build SOURCE_DATE_EPOCH=0 \
  ./build-all.sh ipk arm_cortex-a9 2026.08.08-r1 dist-ipk

./make-runfile.sh --kind ipk --label "daed + salamander" \
  --out dist-run/24-daed-salamander.run dist-ipk/*.ipk
```

The apk format needs `apk mkpkg` from apk-tools >= 3, which is why CI runs that
half inside `alpine:edge`:

```sh
docker run --rm -v "$PWD:/w" -w /w alpine:edge \
  sh -eu packaging/openwrt/build-all.sh apk arm_cortex-a9 2026.08.08-r1 dist-apk
```

Run under `fakeroot` (or as root) or the archived files carry your uid instead
of `0:0`; the script warns when it cannot chown.

## Provenance

- `files/daed.init`, `files/daed.config` — verbatim from the OpenWrt `daed`
  package (ImmortalWrt / QiuSimons' `luci-app-daed`), GPL-2.0-only.
- `luci-app-daed` sources — cloned at build time from a pinned commit, not
  vendored here.
- `po2lmo` — built from `openwrt/luci`'s `modules/luci-base/src`, following that
  Makefile. Note `plural_formula.y` is Lemon (SQLite's parser generator), not
  yacc; `build-po2lmo.sh` builds Lemon first. The `.lmo` this produces is
  byte-identical to the one in the reference package.
- Maintainer-script bodies mirror what OpenWrt's `include/package-pack.mk`
  generates, so `default_postinst` / `default_prerm` behave identically under
  both opkg and apk.
