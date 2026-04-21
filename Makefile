# Top-level driver. Phases stolen from alpine-nanopi-neo-rt:
# kernel → modloop → image. No u-boot or SD-card step — we only produce an
# NVMe-attachable disk image, not a bootable SD image, because the mod's
# flash chip carries OpenSBI+U-Boot separately.

SHELL := /bin/bash
ALPINE_VER ?= 3.23
OUT_DIR    ?= out

# Short form version of Alpine used in the disk image filename (e.g. "3.23").
# The CI workflow overrides this with the exact release (e.g. "3.23.4").
ALPINE_REL ?= $(ALPINE_VER)

.PHONY: all kernel modloop image clean distclean

all: image

kernel:
	tools/build-kernel.sh

modloop: kernel
	tools/build-modloop.sh

image: modloop
	tools/build-nvme-image.sh

# Light clean — keep the kernel source checkout so subsequent rebuilds are
# incremental. Remove only staging / intermediate bits.
clean:
	rm -rf build/staging build/iso build/modloop

# Nuke everything including the kernel source + downloads. Next build will
# re-clone linux and re-fetch Alpine tarballs.
distclean:
	rm -rf build out
