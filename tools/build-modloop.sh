#!/bin/bash
# Pack the staged kernel modules into modloop-lts.
# Matches jbrazio/alpine-nanopi-neo-rt/src/modloop.sh almost verbatim:
# take build/staging/lib/modules → mksquashfs with xz compression into
# out/modloop-lts.
#
# Alpine's init-stage-1 mounts /boot/modloop-lts as a squashfs over
# /.modloop/ and bind-binds /.modloop/modules to /lib/modules. Ours has to
# match that layout (single lib/modules/<ver>/ tree inside the squashfs).

set -euo pipefail

OUT=${OUT_DIR:-out}
STAGING=build/staging
MODLOOP=build/modloop

if [ ! -d "${STAGING}/lib/modules" ]; then
    echo "No staged modules at ${STAGING}/lib/modules. Run build-kernel.sh first." >&2
    exit 1
fi

rm -rf "$MODLOOP"
mkdir -p "$MODLOOP"
cp -aT "${STAGING}/lib/modules" "${MODLOOP}/modules"

# Drop build/source symlinks — they point at the kernel source tree, which
# isn't present inside the modloop and would leave dangling links in the
# guest's /lib/modules/<ver>/ tree.
find "$MODLOOP" -name build -o -name source | xargs -r rm -f

echo "=== Building modloop squashfs ==="
rm -f "${OUT}/modloop-lts"
mksquashfs "$MODLOOP" "${OUT}/modloop-lts" \
    -b 1048576 \
    -comp xz -Xdict-size 100% \
    -root-owned \
    -no-progress

ls -lh "${OUT}/modloop-lts"
