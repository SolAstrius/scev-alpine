{
  description = "Alpine riscv64 kernel + NVMe image builder for Scalar Evolution";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
    ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # pkgsCross.riscv64 is nixpkgs' canonical riscv64-unknown-linux-gnu
        # cross set. buildPackages.gcc drops `riscv64-unknown-linux-gnu-gcc`
        # + matching binutils into the devShell PATH.
        cross = pkgs.pkgsCross.riscv64;
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # --- cross toolchain ---
            cross.buildPackages.gcc
            cross.buildPackages.binutils

            # --- kernel build deps (native) ---
            gnumake
            bc
            bison
            flex
            pkg-config
            openssl
            elfutils
            ncurses
            cpio
            kmod
            perl         # kernel scripts/ uses Perl at build time
            rsync        # headers_install

            # --- filesystem / image packing ---
            squashfsTools
            e2fsprogs
            dosfstools
            util-linux   # sfdisk for partitioning the nvme image

            # --- fetchers / compression / misc ---
            curl
            wget
            git
            xz
            zstd
            python3
            jq
            ccache
          ];

          shellHook = ''
            # Nixpkgs' riscv64 cross toolchain uses the triplet prefix
            # `riscv64-unknown-linux-gnu-`, not Debian's `riscv64-linux-gnu-`.
            # build-kernel.sh respects CROSS_COMPILE from the environment,
            # so override once here and every nested make picks it up.
            export CROSS_COMPILE=riscv64-unknown-linux-gnu-
            export ARCH=riscv

            # Route compiler invocations through ccache. Mirror the CI
            # setup: max-size=1G, LRU eviction handles growth.
            export CCACHE_DIR=''${CCACHE_DIR:-$HOME/.cache/ccache}
            ccache --max-size=1G > /dev/null
            export CROSS_COMPILE="ccache $CROSS_COMPILE"

            echo "scev-alpine devshell loaded."
            echo "  ARCH=$ARCH"
            echo "  CROSS_COMPILE=$CROSS_COMPILE"
            echo "  ccache=$CCACHE_DIR"
            echo
            echo "  make                  full kernel + modloop + image"
            echo "  make kernel           just the kernel"
            echo "  make clean            wipe staging"
            echo "  make distclean        nuke everything including sources"
          '';
        };

        # Expose the kernel build as a flake `build` for `nix build` users
        # who prefer that over direnv + make. Uses the same build.sh drivers
        # via an FHS-ish mkDerivation, ensuring the ccache + toolchain env
        # matches the devShell.
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "scev-alpine-image";
          version = "0.1.0-dev";

          src = self;

          nativeBuildInputs = with pkgs; [
            cross.buildPackages.gcc
            cross.buildPackages.binutils
            gnumake bc bison flex pkg-config perl rsync
            openssl elfutils ncurses cpio kmod
            squashfsTools e2fsprogs dosfstools util-linux
            curl wget git xz zstd python3 jq
          ];

          # Kernel Makefile is fussy about out-of-tree build paths and the
          # sandboxed network means we can't fetch from kernel.org/gitlab;
          # leave `nix build` as a placeholder that reuses the devShell
          # env. For now, instruct users to `nix develop` + `make`.
          buildPhase = ''
            echo "nix build is not wired up — networking is sandboxed."
            echo "Run \`nix develop\` then \`make\` instead."
            exit 1
          '';
          dontInstall = true;
        };
      });
}
