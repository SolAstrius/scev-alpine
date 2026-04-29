#!/bin/bash
# Produce a SYS-INSTALLED Alpine image — pid 1 runs from the disk, not
# from a tmpfs overlay. This is the "real persistence" counterpart to
# build-nvme-image.sh (which produces Alpine's stock live layout).
#
# Layout (ext4 inside MBR partition 1):
#   /sbin/init, /bin, /lib, ...    — Alpine userspace bootstrapped via
#                                    apk.static
#   /boot/vmlinuz-lts              — scev-patched kernel (ours)
#   /boot/initramfs-lts            — Alpine's stock initramfs (fallback;
#                                    the kernel has NVMe + ext4 built-in
#                                    so it can mount root without it)
#   /lib/modules/<kver>            — matching kernel modules
#   /extlinux/extlinux.conf        — points at /boot/vmlinuz-lts,
#                                    root=/dev/nvme0n1p1
#   /etc/hostname, fstab, shadow…  — minimum viable sys config
#
# Boot flow: OpenSBI + U-Boot (from the mod's flash chip) → U-Boot reads
# /extlinux/extlinux.conf from the NVMe → loads vmlinuz-lts → kernel's
# built-in NVMe + ext4 mount /dev/nvme0n1p1 as / → exec /sbin/init → the
# Alpine sys we bootstrapped below. Every subsequent write to /etc, /root,
# /home, /var hits the disk. No apkovl, no lbu, no snapshot daemon.
#
# Output: out/alpine-scev-sysinstall-<ver>-riscv64.img[.zst]

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT_DIR:-out}
BUILD=build
ALPINE_VER=${ALPINE_VER:-3.23}
ALPINE_REL=${ALPINE_REL:-$ALPINE_VER}
MIN_IMG_MB=${MIN_IMG_MB:-1024}   # advertised disk size (matches NvmeItem.SIZE_MB)

# Preflight: must be root. apk.static --initdb refuses non-root, and even
# with --usermode the resulting staging tree would be runner-owned —
# mkfs.ext4 -d would propagate that into the image and the guest's sshd
# would refuse to start (StrictModes), sudo wouldn't be setuid-root, etc.
# CI wraps this with `sudo -E`; local devs typically run inside the
# scev-alpine-builder Docker image (root by default) or via sudo.
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run as root (apk.static --initdb requires it)" >&2
    echo "       Re-invoke with: sudo -E bash $0" >&2
    echo "       Or run inside the scev-alpine-builder Docker image" >&2
    echo "       (Dockerfile at the repo root) which is root by default." >&2
    exit 1
fi

# Preflight: binfmt_misc must have a riscv64 handler registered.
# apk's post-install triggers (busybox sets up /bin/* symlinks, ca-
# certificates rebuilds the bundled cert) are riscv64 ELFs that apk
# execs directly during `apk add`. Without qemu-user-static + binfmt_misc
# the kernel returns ENOEXEC and apk fails with "execve: Exec format error".
#
# Check for /proc/sys/fs/binfmt_misc/qemu-riscv64 — created by either
# `update-binfmts --enable qemu-riscv64` (Debian/Ubuntu binfmt-support)
# or `docker run --privileged --rm tonistiigi/binfmt --install riscv64`
# (the multiarch image). The actual handler name varies slightly
# across distros (qemu-riscv64 vs qemu-riscv64-static), so we glob.
if ! ls /proc/sys/fs/binfmt_misc/qemu-riscv64* >/dev/null 2>&1; then
    echo "ERROR: no riscv64 binfmt_misc handler registered." >&2
    echo "       apk's post-install scripts are riscv64 ELFs and need" >&2
    echo "       qemu-user emulation registered with the kernel to run." >&2
    echo "       Register it with one of:" >&2
    echo "         apt install qemu-user-static binfmt-support" >&2
    echo "         docker run --privileged --rm tonistiigi/binfmt --install riscv64" >&2
    exit 1
fi

mkdir -p "$OUT" "$BUILD"

# --- Resolve ALPINE_REL if a branch name was passed ---------------------

if [ "$ALPINE_REL" = "$ALPINE_VER" ]; then
    echo "=== Resolving Alpine $ALPINE_VER latest point release ==="
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
    echo "    → ${ALPINE_REL}"
fi

# --- Fetch apk-tools-static (host binary that can target riscv64) -------

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    x86_64)  APK_ARCH=x86_64 ;;
    aarch64) APK_ARCH=aarch64 ;;
    *) echo "unsupported host arch: $HOST_ARCH" >&2; exit 1 ;;
esac

APK_REPO="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main/${APK_ARCH}"

echo "=== Fetching apk-tools-static for $APK_ARCH ==="
# The index lists available .apks; pick the highest apk-tools-static.
APKS_LIST=$(curl -fsSL "${APK_REPO}/")
APK_TOOLS_FILE=$(printf '%s\n' "$APKS_LIST" \
    | grep -oE 'apk-tools-static-[0-9][^"]*\.apk' \
    | sort -Vu | tail -1)
if [ -z "$APK_TOOLS_FILE" ]; then
    echo "ERROR: could not find apk-tools-static in ${APK_REPO}" >&2
    exit 1
fi
echo "    → $APK_TOOLS_FILE"
curl -fsSL "${APK_REPO}/${APK_TOOLS_FILE}" -o "${BUILD}/apk-tools-static.apk"

# .apk is a tar.gz in disguise. Extract the static binary.
APK_TOOLS_DIR="${BUILD}/apk-tools-extracted"
rm -rf "$APK_TOOLS_DIR"
mkdir -p "$APK_TOOLS_DIR"
tar -xzf "${BUILD}/apk-tools-static.apk" -C "$APK_TOOLS_DIR" 2>/dev/null \
    || tar -xf "${BUILD}/apk-tools-static.apk" -C "$APK_TOOLS_DIR"
APK_STATIC="${APK_TOOLS_DIR}/sbin/apk.static"
chmod +x "$APK_STATIC"

# Alpine-keys package — needed so the apk's own signed indexes verify.
# Fetch it the same way, extract it into the staging root once we init it.
ALPINE_KEYS_FILE=$(printf '%s\n' "$APKS_LIST" \
    | grep -oE 'alpine-keys-[0-9][^"]*\.apk' \
    | sort -Vu | tail -1)
curl -fsSL "${APK_REPO}/${ALPINE_KEYS_FILE}" -o "${BUILD}/alpine-keys.apk"

# --- Bootstrap the rootfs -----------------------------------------------

STAGING="${BUILD}/sysinstall"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Extract the alpine-keys .apk so we can seed the right signing keys
# into the target before apk.static tries to verify the APKINDEX.
#
# Alpine 3.23 ships apk-tools 3 (written in Rust) which ignores the
# apk2-era --keys-dir flag and instead reads signing keys exclusively
# from the target rootfs's /etc/apk/keys during both install and
# index-verification. The apk .apk itself stores keys in two places:
#
#   usr/share/apk/keys/<ARCH>/     — per-architecture keys that signed
#                                    that arch's APKINDEX. riscv64 is
#                                    signed by exactly two keys
#                                    (60ac2099, 616db30d in Alpine 3.23).
#   etc/apk/keys/                  — a smaller "current signing keys"
#                                    set for target-running apk to trust
#                                    new signatures with.
#
# To avoid UNTRUSTED warnings we pre-seed the target's /etc/apk/keys
# with the riscv64-specific keys BEFORE calling apk.static. apk3 will
# then verify the signed APKINDEX against them as part of its normal
# trust chain — no --allow-untrusted shortcut needed. The installed
# image's /etc/apk/keys gets populated normally by the alpine-keys
# package a moment later, so post-install `apk add` on the running
# guest continues to verify signatures the way Alpine intends.
KEYS_EXTRACT="${BUILD}/alpine-keys-extract"
rm -rf "$KEYS_EXTRACT"
mkdir -p "$KEYS_EXTRACT"
tar -xf "${BUILD}/alpine-keys.apk" -C "${KEYS_EXTRACT}" 2>/dev/null || true

TARGET_ARCH=riscv64
TARGET_ARCH_KEYS_DIR="${KEYS_EXTRACT}/usr/share/apk/keys/${TARGET_ARCH}"
if [ ! -d "$TARGET_ARCH_KEYS_DIR" ]; then
    echo "ERROR: alpine-keys .apk has no keys for ${TARGET_ARCH}" >&2
    exit 1
fi
TARGET_ARCH_KEYS_COUNT=$(ls "$TARGET_ARCH_KEYS_DIR"/*.rsa.pub 2>/dev/null | wc -l)
echo "    → found ${TARGET_ARCH_KEYS_COUNT} ${TARGET_ARCH} signing keys"

MAIN_REPO="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main"
COMMUNITY_REPO="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community"

# Our own signed APK repo (alpine-apks on GH Pages) — ships scev and any
# other custom packages we build. Pinned to the same ALPINE_VER track
# so its APKBUILDs are consistent with the base image's libc/toolchain.
SCEV_REPO="https://solastrius.github.io/alpine-apks/alpine/v${ALPINE_VER}/main"
SCEV_PUBKEY="${ROOT}/config/apk-keys/SolAstrius@alpine-apks.rsa.pub"

# Pre-seed the target's /etc/apk/keys with the riscv64 signing keys
# BEFORE the first APKINDEX fetch. Without this, apk3 would warn
# "UNTRUSTED signature" and silently fail every package selection.
# Also drop in our own signing key so apk trusts the SCEV_REPO index.
mkdir -p "${STAGING}/etc/apk/keys"
cp "$TARGET_ARCH_KEYS_DIR"/*.rsa.pub "${STAGING}/etc/apk/keys/"
if [ -f "$SCEV_PUBKEY" ]; then
    cp "$SCEV_PUBKEY" "${STAGING}/etc/apk/keys/"
    echo "    → trusted scev repo key: $(basename "$SCEV_PUBKEY")"
else
    echo "ERROR: scev repo pubkey missing at $SCEV_PUBKEY" >&2
    exit 1
fi

echo "=== Bootstrapping Alpine riscv64 sys-install at $STAGING ==="
# No --allow-untrusted: the seeded keys above let apk verify the
# APKINDEX normally. No --keys-dir: apk3 ignores that flag and reads
# ${root}/etc/apk/keys directly. Signature chain stays intact end to
# end, including the installed guest's own future `apk add` runs.
#
# Package-download cache: apk's --cache-dir is resolved relative to
# --root (see apk.8 "treated relative to the ROOT"), so a host-side
# absolute path fails with "Unable to setup the cache: No such file
# or directory". Instead we point apk at the standard in-root path
# (var/cache/apk) and shuttle the contents in/out around the install:
# pre-seed from the host-side persistent cache, let apk download-
# or-reuse, copy back out. The existing rm -rf var/cache/apk below
# still clears it before mkfs.ext4 -d so the cached .apks don't
# bloat the shipped image.
#
# --cache-packages explicitly enables cache writes during `add`.
# apk auto-enables it when /etc/apk/cache is a symlink, but we use
# a plain dir so we have to ask for it.
#
# CI persists ${BUILD}/apk-cache via actions/cache to skip the
# ~30–50 MB package download on warm runs (~2–3 min saved). Local
# devs get the same speedup on repeated `make sysinstall` without
# nuking build/.
APK_HOST_CACHE="${BUILD}/apk-cache"
mkdir -p "$APK_HOST_CACHE"
mkdir -p "${STAGING}/var/cache/apk"
if [ -n "$(ls -A "$APK_HOST_CACHE" 2>/dev/null)" ]; then
    echo "    → pre-seeding staging cache from ${APK_HOST_CACHE}"
    cp -a "${APK_HOST_CACHE}/." "${STAGING}/var/cache/apk/"
fi
"$APK_STATIC" \
    --root "$STAGING" \
    --arch "$TARGET_ARCH" \
    --initdb \
    --cache-dir "var/cache/apk" \
    --cache-packages \
    -X "$MAIN_REPO" \
    -X "$COMMUNITY_REPO" \
    -X "$SCEV_REPO" \
    add \
        alpine-base alpine-keys \
        openrc busybox-openrc busybox-mdev-openrc \
        e2fsprogs util-linux \
        sudo nano bash \
        iproute2 ifupdown-ng dhcpcd \
        openssh \
        ca-certificates tzdata \
        mkinitfs \
        alsa-utils \
        scev

# Copy the now-populated staging cache back to the host-side
# persistent cache so the next run reuses these .apks instead of
# re-downloading. cp -a preserves timestamps + permissions, which
# apk uses to decide whether a cached entry is still valid.
if [ -d "${STAGING}/var/cache/apk" ]; then
    echo "    → saving staging cache → ${APK_HOST_CACHE}"
    cp -a "${STAGING}/var/cache/apk/." "${APK_HOST_CACHE}/"
fi

# --- /etc configuration -------------------------------------------------

echo "=== Writing /etc configuration ==="

echo "scev-alpine" > "${STAGING}/etc/hostname"

cat > "${STAGING}/etc/fstab" <<EOF
# scev sys-install. Root is on the preloaded NVMe; everything else is
# tmpfs so write-amplification to the disk is bounded.
/dev/nvme0n1p1  /       ext4        rw,relatime         0 1
proc            /proc   proc        nosuid,noexec,nodev 0 0
sysfs           /sys    sysfs       nosuid,noexec,nodev 0 0
devtmpfs        /dev    devtmpfs    mode=0755,nosuid    0 0
tmpfs           /dev/shm  tmpfs     nosuid,nodev        0 0
tmpfs           /tmp    tmpfs       nosuid,nodev        0 0
tmpfs           /run    tmpfs       nosuid,nodev        0 0
EOF

cat > "${STAGING}/etc/apk/repositories" <<EOF
$MAIN_REPO
$COMMUNITY_REPO
$SCEV_REPO
EOF

cat > "${STAGING}/etc/network/interfaces" <<EOF
# Loopback only. eth0 is handled by the standalone dhcpcd daemon
# (enabled in the default runlevel) — declaring it here too would
# cause ifupdown-ng to also spawn dhcpcd, and two dhcpcd instances on
# the same interface fight over lease state.
auto lo
iface lo inet loopback
EOF

# DNS resolver that works before dhcpcd kicks in — Cloudflare + Google.
cat > "${STAGING}/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Empty root password — this is a Minecraft-mod playground VM, not a
# production host. The image itself lives in the world save so "security"
# is whoever can reach the save file.
sed -i 's|^root:[^:]*:|root::|' "${STAGING}/etc/shadow"

# Enable /etc/securetty entries for our console devices so root can log in.
cat > "${STAGING}/etc/securetty" <<EOF
console
tty0
tty1
ttyS0
ttyS1
EOF

# Allow root login on ssh with empty password (dev mode).
sed -i 's|^#*PermitRootLogin.*|PermitRootLogin yes|' "${STAGING}/etc/ssh/sshd_config"
sed -i 's|^#*PermitEmptyPasswords.*|PermitEmptyPasswords yes|' "${STAGING}/etc/ssh/sshd_config"

# --- OpenRC runlevels ---------------------------------------------------

echo "=== Wiring OpenRC runlevels ==="

# sysinit: first to run, mounts /proc /sys /dev and starts mdev for
# device-tree driven peripherals (i2c-hid keyboard, etc.).
mkdir -p "${STAGING}/etc/runlevels/sysinit"
for svc in devfs dmesg mdev hwdrivers; do
    [ -f "${STAGING}/etc/init.d/$svc" ] \
        && ln -sf "/etc/init.d/$svc" "${STAGING}/etc/runlevels/sysinit/$svc"
done

# boot: filesystems, hostname, module loader.
#
# `modules` reads /etc/modules and loads listed modules. We don't
# populate that file (our primary drivers are built-in), but the
# service remains available as a user-facing hook.
#
# Intentionally NOT enabling `hwclock`: the scev kernel has
# CONFIG_RTC_HCTOSYS=y which syncs /dev/rtc0 into the system clock
# during kernel init (you can see the "goldfish_rtc ...: setting system
# clock to <UTC>" line in dmesg). OpenRC's hwclock service would then
# re-read /dev/rtc0 via userspace `hwclock --hctosys` and — if its
# default config points at /dev/rtc (without a number, which devtmpfs
# doesn't create) — print "Failed to set system clock". The kernel has
# already done the work; a second userspace pass is redundant at best
# and noisy at worst. Skipping the service keeps boot quiet.
mkdir -p "${STAGING}/etc/runlevels/boot"
for svc in bootmisc hostname modules sysctl urandom; do
    [ -f "${STAGING}/etc/init.d/$svc" ] \
        && ln -sf "/etc/init.d/$svc" "${STAGING}/etc/runlevels/boot/$svc"
done

# default: daemons (sshd, dhcpcd) and local.
#
# Networking: exactly ONE DHCP path — the standalone `dhcpcd` daemon
# running in master mode. The daemon auto-discovers every carrier-up
# interface (eth0 from the R8169 PCI NIC) and maintains its lease,
# routing, and DNS until shutdown. `/etc/network/interfaces` is left
# listing only `lo` so ifupdown-ng doesn't also try to invoke dhcpcd
# per-interface — two dhcpcd instances on the same link race each
# other's lease timers and confuse dhcpcd's DAD state machine.
#
# `local` runs /etc/local.d/*.start scripts on entry to the default
# runlevel; a standard Alpine hook.
mkdir -p "${STAGING}/etc/runlevels/default"
for svc in local sshd dhcpcd; do
    [ -f "${STAGING}/etc/init.d/$svc" ] \
        && ln -sf "/etc/init.d/$svc" "${STAGING}/etc/runlevels/default/$svc"
done

# /etc/local.d/scev-netcheck.start — self-diagnostic that polls eth0
# for a DHCP lease and prints the result directly to /dev/ttyS0.
# Writing to ttyS0 (not /dev/console) is deliberate: the cmdline has
# `console=ttyS0,115200 earlycon=sbi console=tty0`, so Linux picks
# the LAST `console=` as /dev/console — that's tty0 (framebuffer).
# The mod's `ScevRpcManager` only drains ttyS0 (the MMIO-backed
# kernel-console UART), so a /dev/console write would disappear into
# the framebuffer instead of reaching the `[scev-kernel <uuid>] ...`
# log stream.
#
# Two purposes:
#   1. Gives the automated `alpine_dhcp_lease_completes` GameTest a
#      deterministic signal to look for (dhcpcd daemon logs via
#      syslog by default — not to the console — so tests can't see
#      its output directly).
#   2. Tells the human user "network is ready (192.168.0.100)" or
#      "no lease after 30s" as a boot diagnostic, without requiring
#      them to run `ip addr` themselves.
#
# Runs as part of the `local` OpenRC service in the default runlevel,
# after `dhcpcd` has already been started (OpenRC orders services by
# their `need`/`after` declarations; `local` has no deps so it races
# dhcpcd's startup, but the 30 s poll budget absorbs the race).
mkdir -p "${STAGING}/etc/local.d"
cat > "${STAGING}/etc/local.d/scev-netcheck.start" <<'EOF'
#!/bin/sh
# Poll eth0 for a DHCPv4 lease and report the result to /dev/ttyS0
# (the mod's kernel-console UART). 30 s budget: dhcpcd needs ~2 s
# to DISCOVER + OFFER + probe + ACK on RVVM's user-mode gateway,
# plus openrc startup overhead.
for _ in $(seq 1 30); do
    addr=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '/inet /{print $4; exit}')
    if [ -n "$addr" ]; then
        gw=$(ip -4 route show default 2>/dev/null | awk '/^default/{print $3; exit}')
        echo "[scev-netcheck] eth0: leased $addr (gw $gw)" > /dev/ttyS0
        exit 0
    fi
    sleep 1
done
echo "[scev-netcheck] eth0: no lease after 30s" > /dev/ttyS0
exit 1
EOF
chmod +x "${STAGING}/etc/local.d/scev-netcheck.start"

# /etc/local.d/scev-sound.start — unmute the HDA codec at boot.
#
# Real HDA codecs default to mute=1 on power-on per spec §7.3.3.7, and
# although our emulated CMedia codec advertises mute=0, Alpine's alsa
# init runs `alsactl init` once when alsa-utils is first installed and
# can capture a transient muted state into /var/lib/alsa/asound.state —
# which then gets restored on every subsequent boot.
#
# Cheaper to just unconditionally unmute + persist on each boot than
# to debug exactly when alsactl decided to save mute=on. amixer / alsactl
# are no-ops if asound has no Master control yet (kernel still loading
# snd_hda_intel) — `|| true` swallows that race; a re-run on the next
# boot will succeed.
#
# Idempotent — safe to run every boot. The `alsactl store` writes the
# same state file alsactl restore reads from, so future boots come up
# unmuted before this script even fires.
cat > "${STAGING}/etc/local.d/scev-sound.start" <<'EOF'
#!/bin/sh
# Wait briefly for the HDA codec to enumerate (kernel module load,
# codec verb probe, mixer control creation). 5 s is generous on RVVM.
for _ in $(seq 1 5); do
    amixer -q sget 'Master' >/dev/null 2>&1 && break
    sleep 1
done
amixer -q sset 'Master' unmute 80% 2>/dev/null || true
alsactl -f /var/lib/alsa/asound.state store 2>/dev/null || true
EOF
chmod +x "${STAGING}/etc/local.d/scev-sound.start"

# Per-tty agetty services. Alpine's agetty-openrc package ships the
# /etc/init.d/agetty template; per-tty instances are created by setup-
# alpine at install time via `rc-update add agetty.<tty> default`.
# We're not running setup-alpine, so create those symlinks ourselves and
# enable them in the default runlevel.
#
#   tty1   — the framebuffer/VT console, which is where RVVM's HID
#            keyboard input lands after going through the simple-fb + vt
#            stack. 38400 baud is meaningless on a VT but expected by
#            agetty; linux term matches what fbcon sets TERM to.
#   ttyS0  — the mod's kernel-console UART. Handy during dev because the
#            server stdout captures everything, including login. 115200
#            baud matches ns16550a_init_auto.
for tty_spec in "tty1:38400:linux" "ttyS0:115200:vt100"; do
    tty=${tty_spec%%:*}
    rest=${tty_spec#*:}
    baud=${rest%%:*}
    term=${rest#*:}
    ln -sf agetty "${STAGING}/etc/init.d/agetty.${tty}"
    ln -sf "/etc/init.d/agetty.${tty}" "${STAGING}/etc/runlevels/default/agetty.${tty}"
    mkdir -p "${STAGING}/etc/conf.d"
    cat > "${STAGING}/etc/conf.d/agetty.${tty}" <<EOF
# Auto-generated by scev-alpine build-nvme-sysinstall.sh — replaces what
# setup-alpine would have written during an interactive sys install.
baud=${baud}
term_type=${term}
agetty_options="--autologin root"
EOF
done

# Override /etc/inittab so busybox-init doesn't fight OpenRC's agetty.
#
# Alpine's stock inittab (shipped by alpine-base) has these entries:
#     tty1::respawn:/sbin/getty 38400 tty1
#     tty2::respawn:/sbin/getty 38400 tty2
#     ...
# On an Alpine sys install setup-alpine REMOVES the tty entries because
# it adds `agetty.ttyN` to the OpenRC default runlevel instead. Without
# this rewrite, BOTH gettys race for tty1: my openrc agetty auto-logs in
# as root + spawns a shell, THEN busybox-init's inittab getty respawns
# and competes for the device, the shell gets EOF, agetty respawns,
# busybox-init respawns its getty, cycle continues. User sees a quick
# login → shell → welcome → login prompt loop and can't type into
# anything stable. Classic double-init bug.
#
# Strip the getty respawn entries and keep only the boot/shutdown
# plumbing. OpenRC's `agetty.tty1` / `agetty.ttyS0` are now the sole
# owners of those TTYs.
cat > "${STAGING}/etc/inittab" <<'EOF'
# Minimal scev sys-install inittab. Getty ownership is exclusive to
# OpenRC's agetty services (see /etc/runlevels/default/agetty.*) — do
# NOT add tty respawn entries here or you'll recreate the double-getty
# race that caused "keyboard doesn't work" on the initial ship.

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

# shutdown: remount-ro, kill services.
mkdir -p "${STAGING}/etc/runlevels/shutdown"
for svc in killprocs mount-ro savecache; do
    [ -f "${STAGING}/etc/init.d/$svc" ] \
        && ln -sf "/etc/init.d/$svc" "${STAGING}/etc/runlevels/shutdown/$svc"
done

# --- Install our kernel + modules --------------------------------------

echo "=== Installing scev kernel + modules ==="

if [ ! -f "${OUT}/vmlinuz-lts" ]; then
    echo "ERROR: ${OUT}/vmlinuz-lts not found — run 'make kernel' first" >&2
    exit 1
fi
# alpine-base (and friends) don't create /boot — that's traditionally
# the responsibility of whichever package installs a kernel. We bring
# our own kernel from scev-alpine so we create the dir ourselves.
mkdir -p "${STAGING}/boot"
cp "${OUT}/vmlinuz-lts" "${STAGING}/boot/vmlinuz-lts"

# Modules tree from build-kernel.sh / build-modloop.sh. We ship them
# unpacked into /lib/modules/<kver>/ so `modprobe` works post-boot even
# without mounting modloop. Modloop is a squashfs optimization for live
# images; on a sys install the rootfs has the modules directly.
MOD_STAGING="${BUILD}/staging/lib/modules"
if [ -d "$MOD_STAGING" ]; then
    mkdir -p "${STAGING}/lib/modules"
    cp -a "$MOD_STAGING"/* "${STAGING}/lib/modules/"

    # Generate module index files (modules.dep, modules.alias, …) so
    # mdev's modprobe hotplug rule (`$MODALIAS=.* @modprobe -b $MODALIAS`
    # in /etc/mdev.conf) can find kernel modules by alias without waiting
    # for `modloop` mount. Without these, modprobe silently fails on a
    # fresh boot — e.g. an RTL8169 NIC that's =m would never attach.
    #
    # depmod from kmod (installed in the builder Dockerfile) is purely
    # offline: it reads ELF metadata out of each .ko and writes the
    # index text files. No target-arch execution required, so cross-arch
    # processing Just Works — as long as we point it at the staging root
    # via `-b` and pass the kernel version found in the modules dir.
    KVER=$(ls "${STAGING}/lib/modules/" | head -1)
    if [ -n "$KVER" ] && command -v depmod >/dev/null 2>&1; then
        echo "=== Running depmod -b ${STAGING} ${KVER} ==="
        depmod -b "${STAGING}" "${KVER}"
    else
        echo "WARN: depmod unavailable or no modules dir — mdev-triggered modprobe will fail" >&2
    fi
fi

# --- extlinux.conf -----------------------------------------------------
mkdir -p "${STAGING}/extlinux"
cat > "${STAGING}/extlinux/extlinux.conf" <<EOF
# Boot config for U-Boot's distro_bootcmd / sysboot. The kernel has
# NVMe + ext4 built-in (see scev-alpine's config/scev.config) so it can
# mount root directly from the cmdline without an initramfs.
#
# console ordering: ttyS0 first so kernel log goes to the mod's UART
# (visible in server stdout during development), tty0 LAST so getty
# respawns on the framebuffer and the login prompt lands on the in-game
# screen.
DEFAULT scev
TIMEOUT 10
PROMPT 0

LABEL scev
    MENU LABEL Alpine Linux (scev sys-install)
    LINUX /boot/vmlinuz-lts
    APPEND root=/dev/nvme0n1p1 rw rootfstype=ext4 console=ttyS0,115200 earlycon=sbi console=tty0 8250.nr_uarts=32
EOF
# 8250.nr_uarts=32 — Alpine builds the kernel with CONFIG_SERIAL_8250_NR_UARTS=4,
# which collides with RVVM mods that attach an Exar XR17V35x PCIe combo card
# (up to 16 ports). PCI probes before of_serial, so the 4 default slots fill
# with Exar ports and the on-board ns16550a loses its registration silently.
# 32 covers the worst case (16 Exar + on-board) with headroom.

# --- Clean cache + temp artifacts --------------------------------------

echo "=== Cleaning apk caches ==="
rm -rf "${STAGING}/var/cache/apk/"*
rm -rf "${STAGING}/var/tmp/"*

# --- Build the disk image ----------------------------------------------

PART_START_KB=1024
SIZE_KB=$(du -sk "$STAGING" | cut -f1)
# Compute required size with 20% headroom + boot-region, round up to MiB,
# then clamp up to MIN_IMG_MB so the shipped image matches the tooltip.
COMPUTED_KB=$(( (SIZE_KB * 120 / 100 + PART_START_KB + 1023) / 1024 * 1024 ))
MIN_IMG_KB=$(( MIN_IMG_MB * 1024 ))
IMG_KB=$(( COMPUTED_KB > MIN_IMG_KB ? COMPUTED_KB : MIN_IMG_KB ))
FS_KB=$(( IMG_KB - PART_START_KB ))
FS_OFFSET_BYTES=$(( PART_START_KB * 1024 ))

IMG="${OUT}/alpine-scev-sysinstall-${ALPINE_REL}-riscv64.img"
echo "=== Packing disk image: ${IMG_KB} KiB total, ${FS_KB} KiB ext4, content ~${SIZE_KB} KiB ==="

truncate -s "${IMG_KB}K" "$IMG"
echo 'start=2048, type=83, bootable' | sfdisk --quiet "$IMG"
mkfs.ext4 -F -q \
    -E offset="$FS_OFFSET_BYTES" \
    -L SCEV_ALPINE \
    -U deadbeef-cafe-beef-feed-a1befacefeed \
    -d "$STAGING" \
    "$IMG" \
    "${FS_KB}K"

echo "=== Compressing + signing ==="
zstd -f -19 -T0 -o "${IMG}.zst" "$IMG"
ls -lh "$IMG" "${IMG}.zst"
(cd "$OUT" && sha256sum "$(basename "$IMG")" "$(basename "${IMG}.zst")" >> SHA256SUMS)

echo
echo "=== Done. Sys-install image: ${IMG} ==="
