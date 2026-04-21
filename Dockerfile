# Build environment for scev-alpine. Based on the pattern used by
# jbrazio/alpine-nanopi-neo-rt — Debian host with a riscv64 cross-toolchain
# and enough userspace tooling to cross-compile Linux, pack squashfs, and
# build ext4 images. Chosen over Ubuntu because gcc-riscv64-linux-gnu is
# available out of the box in Debian trixie and bookworm-backports.

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        # cross toolchain
        gcc-riscv64-linux-gnu \
        libc6-dev-riscv64-cross \
        # kernel build deps
        bc bison flex libssl-dev libelf-dev libncurses-dev \
        build-essential cpio kmod \
        # filesystem tooling
        squashfs-tools e2fsprogs fdisk dosfstools \
        # networking / fetch
        ca-certificates curl wget \
        git \
        # misc
        xz-utils zstd rsync pigz python3 jq \
    && rm -rf /var/lib/apt/lists/*

# Nice-to-haves; don't fail if unavailable on a given base
RUN apt-get update && apt-get install -y --no-install-recommends \
        ccache \
    && rm -rf /var/lib/apt/lists/* || true

ENV ARCH=riscv
ENV CROSS_COMPILE=riscv64-linux-gnu-
ENV PATH=/usr/lib/ccache:$PATH

WORKDIR /work
