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

# Patch Alpine's stock extlinux.conf to route the kernel console to our
# UART + framebuffer, and drop `quiet` so boot output is visible in dev.
#
# Alpine's default APPEND is
#     modules=loop,squashfs,sd-mod,usb-storage quiet
# which works on real boards where U-Boot pre-configures a console the
# kernel inherits. On RVVM the kernel needs to be told explicitly:
#     console=ttyS0,115200   — the mod's kernel-console UART (ttyS0)
#     console=tty0           — the framebuffer, so Alpine login lands on
#                              the workstation screen
#     earlycon=sbi           — visible before simple-framebuffer attaches
# Order matters: Linux picks the LAST `console=` as /dev/console, which
# is where getty respawns, so tty0 is last → login prompt on the screen.
EXTLINUX="${ROOTFS}/extlinux/extlinux.conf"
python3 - "$EXTLINUX" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
def rewrite_append(m):
    existing = m.group(1).split()
    # Drop `quiet` — we want to see boot output.
    filtered = [w for w in existing if w != "quiet"]
    # Drop any pre-existing console=/earlycon= so we don't stack them.
    filtered = [w for w in filtered if not w.startswith(("console=", "earlycon="))]
    # Append ours in the right order.
    filtered += ["console=ttyS0,115200", "earlycon=sbi", "console=tty0"]
    return "APPEND " + " ".join(filtered)
text = re.sub(r"APPEND\s+(.*)", rewrite_append, text)
with open(path, "w") as f:
    f.write(text)
PY

echo "=== extlinux.conf (patched) ==="
sed 's/^/    /' "$EXTLINUX"

# Pack into a partitioned disk image. Layout:
#
#   byte 0      MBR with one bootable Linux (0x83) partition
#   byte 1 MiB  partition 1 start (2048-sector aligned)
#   ...         ext4 filesystem with the Alpine boot layout
#
# U-Boot 2023.04's distro-boot scans for bootable partitions via
# `part list -bootable`; an unpartitioned raw filesystem returns no
# matches and boot falls through to EFI / nothing. Empirically verified
# in the mod — OpenSBI → U-Boot → "No partition table - nvme 0" → drop
# to prompt. Wrapping in MBR unblocks extlinux.conf detection.
#
# No losetup / sudo needed: mkfs.ext4 -E offset= operates inside a
# pre-sized file, so the whole build stays rootless.
PART_START_KB=1024                                # 1 MiB boot-alignment conventional
SIZE_KB=$(du -sk "$ROOTFS" | cut -f1)
# Sum footprint + 20% headroom + partition-table space, round up to MiB.
IMG_KB=$(( (SIZE_KB * 120 / 100 + PART_START_KB + 1023) / 1024 * 1024 ))
FS_KB=$(( IMG_KB - PART_START_KB ))
FS_OFFSET_BYTES=$(( PART_START_KB * 1024 ))
IMG="${OUT}/alpine-scev-${ALPINE_REL}-riscv64.img"

echo "=== Packing partitioned disk image (${IMG_KB} KiB total, ${FS_KB} KiB filesystem) ==="

# Create the sparse backing file.
truncate -s "${IMG_KB}K" "$IMG"

# Write MBR: one primary partition starting at sector 2048 (1 MiB),
# type 0x83 (Linux), marked bootable so U-Boot's `part list -bootable`
# picks it up.
echo 'start=2048, type=83, bootable' | sfdisk --quiet "$IMG"

# mkfs.ext4 inside the partition window. -E offset= skips the MBR
# region, final positional arg limits filesystem size to the partition
# (otherwise mkfs would try to fill the whole image including offset).
mkfs.ext4 -F -q \
    -E offset="$FS_OFFSET_BYTES" \
    -L SCEV_ALPINE \
    -U deadbeef-cafe-beef-feed-a1befacefeed \
    -d "$ROOTFS" \
    "$IMG" \
    "${FS_KB}K"

echo "=== Compressing for release ==="
# Keep both the raw .img (for consumers that can't decompress zstd —
# e.g. the mod's Gradle fetch task) and the .img.zst (~35% smaller for
# bandwidth-constrained consumers). --rm dropped so $IMG survives.
zstd -f -19 -T0 -o "${IMG}.zst" "$IMG"
ls -lh "${IMG}" "${IMG}.zst"
sha256sum "${IMG}" "${IMG}.zst" > "${OUT}/SHA256SUMS"

echo
echo "=== Done ==="
echo "    Image : ${IMG}.zst"
echo "    Sums  : ${OUT}/SHA256SUMS"
