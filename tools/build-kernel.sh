#!/bin/bash
# Cross-compile a linux-lts-scev kernel for riscv64:
#   1. Resolve Alpine's current linux-lts version from aports.
#   2. Clone that exact Linux tag from git.kernel.org (not Alpine's apk,
#      so we don't drag in Alpine's build tooling — we only want source).
#   3. Merge Alpine's config-lts.riscv64 with our config/scev.config delta.
#   4. `make olddefconfig && make -j Image modules`.
#   5. Drop vmlinuz (gunzipped Image) and a staged modules/ tree into out/.
#
# Pattern adapted from jbrazio/alpine-nanopi-neo-rt's src/kernel.sh — same
# phases (clone → patch/merge → make), swap arm-for-riscv, swap RT patch
# for a config merge.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT_DIR:-out}
BUILD=build
STAGING=${BUILD}/staging
ALPINE_VER=${ALPINE_VER:-3.23}

mkdir -p "$OUT" "$BUILD" "$STAGING"

echo "=== Resolving Alpine $ALPINE_VER linux-lts version ==="
# aports lives on gitlab.alpinelinux.org; raw file access via the HTTP API.
APKBUILD_URL="https://gitlab.alpinelinux.org/alpine/aports/-/raw/${ALPINE_VER}-stable/main/linux-lts/APKBUILD"
APKBUILD="${BUILD}/APKBUILD.lts.${ALPINE_VER}"
curl -fsSL "$APKBUILD_URL" -o "$APKBUILD"
KVER=$(sed -n 's/^pkgver=//p' "$APKBUILD")
KREL=$(sed -n 's/^pkgrel=//p' "$APKBUILD")
echo "    → Alpine linux-lts ${KVER}-r${KREL}"

# Upstream Linux tarball from kernel.org, not a git clone — tarballs are
# faster, don't drag .git metadata, and match how Alpine packages the
# source in their APKBUILD.
KTAR="linux-${KVER}.tar.xz"
KTAR_URL="https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/${KTAR}"
if [ ! -f "${BUILD}/${KTAR}" ]; then
    echo "=== Fetching ${KTAR} ==="
    curl -fL --progress-bar "$KTAR_URL" -o "${BUILD}/${KTAR}"
fi

KSRC="${BUILD}/linux-${KVER}"
if [ ! -d "$KSRC" ]; then
    echo "=== Extracting ${KTAR} ==="
    tar -C "$BUILD" -xf "${BUILD}/${KTAR}"
fi

echo "=== Fetching Alpine's linux-lts config for riscv64 ==="
# Aports naming: main/linux-lts/lts.<arch>.config (flavor-first, not
# config-first — cf. main/linux-lts/ listing in aports).
ACFG_URL="https://gitlab.alpinelinux.org/alpine/aports/-/raw/${ALPINE_VER}-stable/main/linux-lts/lts.riscv64.config"
ACFG="${BUILD}/alpine.config"
curl -fsSL "$ACFG_URL" -o "$ACFG"

echo "=== Merging Alpine config + scev.config delta ==="
# merge_config.sh is the in-kernel tool designed exactly for this job: it
# overlays fragments on a base .config, warns on conflicts, and runs
# olddefconfig afterwards to resolve transitive deps.
cp "$ACFG" "${KSRC}/.config"
bash "${KSRC}/scripts/kconfig/merge_config.sh" -m \
    -O "$KSRC" \
    "${KSRC}/.config" \
    "${ROOT}/config/scev.config"

echo "=== Building kernel + modules ==="
export ARCH=riscv
export CROSS_COMPILE=${CROSS_COMPILE:-riscv64-linux-gnu-}
JOBS=$(nproc)
make -C "$KSRC" -j"$JOBS" olddefconfig
make -C "$KSRC" -j"$JOBS" Image modules

echo "=== Installing modules into staging ==="
rm -rf "$STAGING"
mkdir -p "$STAGING"
make -C "$KSRC" INSTALL_MOD_PATH="$(realpath "$STAGING")" modules_install

# Alpine expects the kernel filename to be vmlinuz-lts. Strip the Image
# gzip wrapper if present — arch/riscv/boot/Image is the raw (uncompressed)
# kernel binary on riscv64.
cp "${KSRC}/arch/riscv/boot/Image" "${OUT}/vmlinuz-lts"

# Also copy the kernel's own .config so the release is self-describing.
cp "${KSRC}/.config" "${OUT}/config-${KVER}-lts-scev.riscv64"

echo
echo "=== Summary ==="
echo "    kernel:  $(ls -lh "${OUT}/vmlinuz-lts" | awk '{print $5}')"
echo "    modules: $(find "$STAGING/lib/modules" -name '*.ko' | wc -l) .ko files"
echo "    version: ${KVER} (from Alpine $ALPINE_VER linux-lts r${KREL})"
echo "    KVER=${KVER}" > "${BUILD}/kver"
