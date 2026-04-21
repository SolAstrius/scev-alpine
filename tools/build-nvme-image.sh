#!/bin/bash
# Produce the final consumer artefact: an ext4 disk image the mod attaches
# as NVMe. Layout mirrors Alpine's Generic U-Boot tarball so U-Boot's
# extlinux-bootflow handler finds `/extlinux/extlinux.conf` on scan and
# boots /boot/vmlinuz-lts + /boot/initramfs-lts automatically.
#
#     /boot/vmlinuz-lts         ← ours (scev-patched)
#     /boot/modloop-lts         ← ours (matching modules)
#     /boot/initramfs-lts       ← Alpine's (from the upstream tarball;
#                                  its module detection loads what we need)
#     /extlinux/extlinux.conf   ← Alpine's (with root= adjusted if needed)
#
# Output: out/alpine-scev-<ver>-riscv64.img[.zst]

set -euo pipefail

OUT=${OUT_DIR:-out}
BUILD=build
ALPINE_VER=${ALPINE_VER:-3.23}
# Exact release used for the initramfs + extlinux.conf. CI sets this to
# the current point release (e.g. 3.23.4); default to "latest" resolution
# via the release manifest.
ALPINE_REL=${ALPINE_REL:-$ALPINE_VER}

if [ "$ALPINE_REL" = "$ALPINE_VER" ]; then
    # Resolve the latest point release for the given branch by parsing
    # latest-releases.yaml and picking out the alpine-uboot flavour. The
    # YAML is one record per block, separated by a top-level `-`; awk-only
    # parsing is fragile because `version:` lands BEFORE `flavor:` in each
    # block, so state has to be carried. Use python3 — CI installs it
    # anyway for other steps, and the parser is obvious.
    ALPINE_REL=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/riscv64/latest-releases.yaml" \
        | python3 -c '
import sys, re
block = {}
def emit(b):
    if b.get("flavor") == "alpine-uboot":
        print(b["version"])
        sys.exit(0)
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if re.match(r"^-\s*$", line):
        emit(block); block = {}
    else:
        m = re.match(r"^\s+(\w+):\s*(.*)$", line)
        if m: block[m.group(1)] = m.group(2).strip().strip("\"")
emit(block)
sys.exit("no alpine-uboot entry found in latest-releases.yaml")
')
    if [ -z "$ALPINE_REL" ]; then
        echo "Failed to resolve Alpine $ALPINE_VER latest release" >&2
        exit 1
    fi
    echo "    Resolved Alpine $ALPINE_VER latest release: ${ALPINE_REL}"
fi

TARBALL="alpine-uboot-${ALPINE_REL}-riscv64.tar.gz"
TARBALL_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/riscv64/${TARBALL}"

if [ ! -f "${BUILD}/${TARBALL}" ]; then
    echo "=== Downloading ${TARBALL} ==="
    curl -fL --progress-bar "$TARBALL_URL" -o "${BUILD}/${TARBALL}"
fi

ROOTFS="${BUILD}/iso"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

echo "=== Extracting Alpine U-Boot tarball ==="
tar -C "$ROOTFS" -xf "${BUILD}/${TARBALL}"

# The tarball layout has everything under `/boot/`, `/extlinux/`,
# `/u-boot/`, `/apks/`. We don't ship the u-boot/ directory — OpenSBI+U-Boot
# comes from the mod's flash chip, not from the NVMe.
rm -rf "${ROOTFS}/u-boot"

echo "=== Swapping kernel + modloop ==="
cp "${OUT}/vmlinuz-lts" "${ROOTFS}/boot/vmlinuz-lts"
cp "${OUT}/modloop-lts" "${ROOTFS}/boot/modloop-lts"

# extlinux.conf carries a root= pointing at boot media; for our usage,
# Alpine's stock value is fine (`modloop=/boot/modloop-lts` → modloop is
# local to this device). Record what's there for debugging.
echo "=== extlinux.conf (unchanged) ==="
cat "${ROOTFS}/extlinux/extlinux.conf" | sed 's/^/    /'

# Pack into an ext4 image sized with ~20% headroom over the content
# footprint. Rounded up to the nearest MiB.
SIZE_KB=$(du -sk "$ROOTFS" | cut -f1)
IMG_KB=$(( (SIZE_KB * 120 / 100 + 1023) / 1024 * 1024 ))  # round up to MiB
IMG="${OUT}/alpine-scev-${ALPINE_REL}-riscv64.img"

echo "=== Packing ext4 image (${IMG_KB} KiB) ==="
dd if=/dev/zero of="$IMG" bs=1024 count="$IMG_KB" status=none
# mkfs.ext4 with a deterministic UUID/label so the mod can reference the
# volume label rather than relying on file-path probing.
mkfs.ext4 -F -q \
    -L SCEV_ALPINE \
    -U deadbeef-cafe-beef-feed-a1befacefeed \
    -d "$ROOTFS" \
    "$IMG"

echo "=== Compressing for release ==="
zstd -f -19 -T0 --rm -o "${IMG}.zst" "$IMG"
ls -lh "${IMG}.zst"
sha256sum "${IMG}.zst" > "${OUT}/SHA256SUMS"

echo
echo "=== Done ==="
echo "    Image : ${IMG}.zst"
echo "    Sums  : ${OUT}/SHA256SUMS"
