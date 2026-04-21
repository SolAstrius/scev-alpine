# scev-alpine

Alpine Linux riscv64 kernel + disk image tailored for the devices that RVVM
(and therefore the [Scalar Evolution][scev] Minecraft mod) exposes to its
guest.

Stock Alpine's `linux-lts` riscv64 kernel targets `qemu-virt` and is missing a
handful of drivers we need — notably `I2C_OCORES` (the bus controller RVVM
hangs its keyboard/mouse off) and `I2C_HID_OF` (the DT-binding path that
attaches HID devices over that bus). Without them, an otherwise-working
Alpine boots to a login prompt with a dead keyboard.

This repo produces a drop-in replacement: same Alpine userspace, different
kernel binaries, wrapped into an NVMe-attachable disk image the mod ships as
a preloaded-disk asset.

## Outputs

Per build, uploaded as GitHub Release assets:

- `vmlinuz-lts-scev-<ver>-riscv64` — cross-compiled kernel image
- `modloop-lts-scev-<ver>-riscv64` — squashfs of matching kernel modules
- `alpine-scev-<ver>-riscv64.img.zst` — ext4 disk image ready to attach as
  NVMe. Contains Alpine's generic-U-Boot layout (`/boot/vmlinuz-lts`,
  `/boot/initramfs-lts`, `/boot/modloop-lts`, `/extlinux/extlinux.conf`)
  with the kernel + modloop replaced by ours.
- `SHA256SUMS` — checksums, signed with the build signing key.

## Kernel config deltas

See [`config/scev.config`](config/scev.config). The high-level additions over
Alpine's `config-lts.riscv64`:

| Option | Rationale |
| :-- | :-- |
| `CONFIG_I2C_OCORES=m` | RVVM's I²C bus controller (OpenCores) |
| `CONFIG_I2C_HID_OF=m` | DT-bound HID path (keyboard + mouse) |
| `CONFIG_SND_HDA_INTEL=m` | HDA controller driver |
| `CONFIG_SND_HDA_CODEC_CMEDIA=m` | codec driver for RVVM's CM8888 |
| `CONFIG_GPIO_SIFIVE=m` | RVVM's SiFive GPIO peripheral (MCU tier) |

All as modules so they load from initramfs / modloop without forcing a
monolithic kernel.

## Build locally

Requires Docker:

```bash
docker build -t scev-alpine-builder .
docker run --rm -v "$PWD:/work" -w /work scev-alpine-builder \
    sh -c 'make ALPINE_VER=3.23 all'
```

Output lands in `out/`.

## CI

`.github/workflows/build.yml` runs the same pipeline on ubuntu-latest.
Triggers:

- Weekly schedule (Monday 06:00 UTC) — tracks Alpine point releases.
- Manual `workflow_dispatch` — for adhoc rebuilds.
- Push to `main` that touches `config/**`, `tools/**`, or the workflow itself.

On success, the workflow tags a release as `alpine-<ver>-scev<N>` and attaches
the artefacts.

## Relationship to the mod

The Scalar Evolution mod's `build.gradle` fetches the latest signed release
and drops the disk image into the mod jar under
`src/main/resources/assets/scev/firmware/`. Players who equip a workstation
with a "preloaded Alpine" NVMe get this image at first boot.

## License

MPL-2.0 for our recipes + wrappers. Each produced artefact carries the
licensing of its upstream components: Linux kernel under GPL-2.0, Alpine
packages under their respective licenses.

[scev]: https://github.com/pufit/ScalarEvolution2
