#!/usr/bin/env bash
#
<<<<<<< HEAD
# build.sh - PoWeR kernel builder for begonia (Redmi Note 8 Pro, MT6785)
=======
# build.sh - Portable MeTh kernel builder & AnyKernel3 flashable zip packager
# For Redmi Note 8 Pro (begonia, MT6785)
>>>>>>> 5e8a57559aed (build: add portable build system, AnyKernel3 packaging and clean CI)
#
# Dependencies are fully self-contained inside ./kerdevdep
# Builds and flashable zips are placed in ./build
#
<<<<<<< HEAD
# Requirements: bash, curl, tar, unzip, zip, cpio, make, python3
#
# Environment overrides:
#   KERNEL_NAME   zip/kernel name (default: PoWeR-Kernel-begonia)
#   CLANG_VER     android clang release, e.g. clang-r383902 (default)
#   GCC_VER       gcc version tag, e.g. android-11.0.0_r1 (default)
#   TC_ROOT       directory where toolchains are stored (default: $HOME/toolchains)
#   OUT_DIR       kernel out directory (default: out)
#   DEFCONFIG     kernel defconfig (default: begonia_apatch_defconfig; use
#                 begonia_user_defconfig for a plain non-APatch build)
#   CLANG_DIR     preinstalled clang prefix dir (bin/clang expected inside)
#   GCC_DIR       preinstalled binutils prefix dir (bin/aarch64-linux-android-* inside)
#   JOBS          build jobs (default: $(nproc))
#   SKIP_CLEAN    set to 1 to reuse an existing out/ tree
#   SKIP_PACKAGE  set to 1 to skip making the flashable zip
#   KEEP_CUSTOM_FLAGS
#                 set to 1 to keep CONFIG_LLVM_POLLY / CONFIG_INLINE_OPTIMIZATION
#                 even if the toolchain does not support the custom -mllvm flags
#                 (only use with a patched/MTK clang that supports them)
#   EXTRA_FLAGS   extra flags appended to both make invocations

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_NAME="${KERNEL_NAME:-PoWeR-Kernel-begonia}"
CLANG_VER="${CLANG_VER:-clang-r383902}"
GCC_VER="${GCC_VER:-android-11.0.0_r1}"
TC_ROOT="${TC_ROOT:-$HOME/toolchains}"
OUT_DIR="${OUT_DIR:-out}"
=======
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/out}"
KERDEVDEP="${KERDEVDEP:-$ROOT_DIR/kerdevdep}"
KERNEL_NAME="${KERNEL_NAME:-Pox-Kernel-begonia}"
DEFCONFIG="${DEFCONFIG:-begonia_apatch_defconfig}"
>>>>>>> 5e8a57559aed (build: add portable build system, AnyKernel3 packaging and clean CI)
JOBS="${JOBS:-$(nproc)}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
DATE="$(date +%Y%m%d-%H%M)"

log()  { printf '\033[1;32m[*] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[-] %s\033[0m\n' "$*"; }

# 1. Ensure kerdevdep is bootstrapped
if [[ ! -f "$KERDEVDEP/env.sh" || ! -x "$KERDEVDEP/clang/bin/clang" ]]; then
    log "Bootstrapping self-contained dependencies in $KERDEVDEP ..."
    bash "$KERDEVDEP/setup_kerdevdep.sh"
fi

# 2. Source kerdevdep environment
# shellcheck source=/dev/null
source "$KERDEVDEP/env.sh"

ARCH=arm64
CC=clang
CLANG_TRIPLE=aarch64-linux-gnu-
CROSS_COMPILE=aarch64-linux-android-
AK3_DIR="$KERDEVDEP/anykernel"

<<<<<<< HEAD
log() { printf '\033[1;32m[*] %s\033[0m\n' "$*"; }
=======
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-TXO_R}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-PoxKernel}"
>>>>>>> 5e8a57559aed (build: add portable build system, AnyKernel3 packaging and clean CI)

ACTION="${1:-all}"

clean_build() {
    log "Cleaning build outputs in $OUT_DIR ..."
    rm -rf "$OUT_DIR"
    log "Clean complete."
}

distclean_build() {
    log "Removing entire build directory $BUILD_DIR ..."
    rm -rf "$BUILD_DIR"
    log "Distclean complete."
}

prepare_config() {
    local test_src="$BUILD_DIR/.tc-test.c"
    mkdir -p "$BUILD_DIR"
    printf 'int x;\n' > "$test_src"

    if [[ "${KEEP_CUSTOM_FLAGS:-0}" == "1" ]]; then
        log "KEEP_CUSTOM_FLAGS=1 - keeping custom -mllvm flags"
        rm -f "$test_src"
        return
    fi

    if ! "$KERDEVDEP/clang/bin/clang" --target=aarch64-linux-gnu \
        -mllvm -polly -mllvm -polly-postopts=1 -mllvm -polly-ast-use-context \
        -mllvm -polly-detect-keep-going -mllvm -polly-vectorizer=stripmine \
        -mllvm -polly-invariant-load-hoisting -c "$test_src" -o /dev/null 2>/dev/null; then
        log "Toolchain lacks patched LLVM Polly - disabling CONFIG_LLVM_POLLY"
        ./scripts/config --file "$OUT_DIR/.config" --disable LLVM_POLLY
    fi

    if ! "$KERDEVDEP/clang/bin/clang" --target=aarch64-linux-gnu \
        -mllvm -unroll-threshold=1200 -mllvm -unroll-threshold=900 \
        -mllvm -inline-threshold=2000 -mllvm -inline-threshold=1300 \
        -c "$test_src" -o /dev/null 2>/dev/null; then
        log "Toolchain rejects repeated -mllvm thresholds - disabling CONFIG_INLINE_OPTIMIZATION"
        ./scripts/config --file "$OUT_DIR/.config" --disable INLINE_OPTIMIZATION
    fi
<<<<<<< HEAD
=======

    # shellcheck disable=SC2086
>>>>>>> 5e8a57559aed (build: add portable build system, AnyKernel3 packaging and clean CI)
    make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS olddefconfig
    rm -f "$test_src"
}

run_menuconfig() {
    mkdir -p "$OUT_DIR"
    if [[ ! -f "$OUT_DIR/.config" ]]; then
        log "Generating defconfig ($DEFCONFIG) ..."
        # shellcheck disable=SC2086
        make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
            CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
            $EXTRA_FLAGS "$DEFCONFIG"
        prepare_config
    fi
    make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        menuconfig
}

build_kernel() {
    log "================================================="
    log "Building $KERNEL_NAME"
    log "Defconfig:   $DEFCONFIG"
    log "Output Dir:  $BUILD_DIR"
    log "Object Dir:  $OUT_DIR"
    log "Jobs:        $JOBS"
    log "Toolchain:   $KERDEVDEP"
    log "================================================="

    local bcc="$CC"
    if command -v ccache >/dev/null 2>&1 && [[ "${CCACHE:-1}" == "1" ]]; then
        bcc="ccache $CC"
        export CCACHE_DIR="${CCACHE_DIR:-$BUILD_DIR/.ccache}"
        mkdir -p "$CCACHE_DIR"
        log "Using ccache (cache dir: $CCACHE_DIR)"
    fi

    mkdir -p "$OUT_DIR" "$BUILD_DIR"
    cd "$ROOT_DIR"
<<<<<<< HEAD
    make O="$OUT_DIR" ARCH="$ARCH" CC="$bcc" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS "$DEFCONFIG"
    prepare_config
=======

    if [[ ! -f "$OUT_DIR/.config" ]]; then
        log "Configuring with $DEFCONFIG ..."
        # shellcheck disable=SC2086
        make O="$OUT_DIR" ARCH="$ARCH" CC="$bcc" \
            CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
            $EXTRA_FLAGS "$DEFCONFIG"
        prepare_config
    else
        log "Reusing existing .config in $OUT_DIR"
    fi

    if grep -q '^CONFIG_KALLSYMS_ALL=y$' "$OUT_DIR/.config"; then
        log "CONFIG_KALLSYMS_ALL=y verified (APatch supported)."
    fi

    log "Starting kernel compilation..."
    # shellcheck disable=SC2086
>>>>>>> 5e8a57559aed (build: add portable build system, AnyKernel3 packaging and clean CI)
    make O="$OUT_DIR" ARCH="$ARCH" CC="$bcc" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS -j"$JOBS"

    local image="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
    if [[ ! -f "$image" ]]; then
        err "Build failed: $image was not produced."
        exit 1
    fi

    cp -f "$image" "$BUILD_DIR/Image.gz-dtb"
    log "Kernel image saved to: $BUILD_DIR/Image.gz-dtb"
}

package_zip() {
    if [[ "${SKIP_PACKAGE:-0}" == "1" ]]; then
        log "Skipping zip packaging."
        return
    fi

    local image="$BUILD_DIR/Image.gz-dtb"
    if [[ ! -f "$image" ]]; then
        if [[ -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" ]]; then
            cp -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" "$image"
        else
            err "Cannot package zip: $image does not exist. Run build first."
            exit 1
        fi
    fi

    local stage="$BUILD_DIR/.anykernel_stage"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -r "$AK3_DIR/." "$stage/"
    cp "$image" "$stage/Image.gz-dtb"

    local commit_hash
    commit_hash="$(git rev-parse --short HEAD 2>/dev/null || echo "custom")"

    cat << AK_EOF > "$stage/anykernel.sh"
# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers
# Configured for Pox Kernel by TXO R

## AnyKernel setup
properties() { '
kernel.string=Pox Kernel by TXO R for Redmi Note 8 Pro (begonia)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=begonia
device.name2=begonia_in
device.name3=begoniain
device.name4=
supported.versions=
supported.patchlevels=
'; } # end properties

## shell variables
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## TWRP / Recovery UI Banner
ui_print " ";
ui_print " ============================================";
ui_print "                 POX KERNEL                  ";
ui_print " ============================================";
ui_print "  * Device     : Redmi Note 8 Pro (begonia)  ";
ui_print "  * Maintainer : TXO R                       ";
ui_print "  * Motto      : We aim for stability,       ";
ui_print "                 not for anything else.      ";
ui_print "  * Commit     : $commit_hash";
ui_print "  * Features   : APatch / KernelPatch ready  ";
ui_print " ============================================";
ui_print " ";

## AnyKernel file attributes
ui_print " [*] [1/4] Configuring ramdisk permissions & ownership...";
chmod -R 750 \$RAMDISK/*;
chown -R root:root \$RAMDISK/*;

## AnyKernel install
ui_print " [*] [2/4] Dumping and unpacking current boot image...";
dump_boot;

ui_print " [*] [3/4] Repacking boot image with Pox kernel (Image.gz-dtb)...";
write_boot;

ui_print " [*] [4/4] Cleaning up temporary installer files...";
ui_print " ";
ui_print " ============================================";
ui_print "      POX KERNEL INSTALLED SUCCESSFULLY!     ";
ui_print "   We aim for stability, not for anything else.";
ui_print "      Reboot and enjoy solid stability.      ";
ui_print " ============================================";
ui_print " ";
## end install
AK_EOF

    local zip_file="$BUILD_DIR/$KERNEL_NAME-$commit_hash.zip"
    log "Packaging AnyKernel3 flashable zip: $zip_file"
    (cd "$stage" && zip -r9 "$zip_file" . -x '*.git*' -x '.github*')
    rm -rf "$stage"

    # Also maintain latest.zip and date-stamped copies in build/
    cp -f "$zip_file" "$BUILD_DIR/$KERNEL_NAME-$DATE.zip"
    ln -sf "$(basename "$zip_file")" "$BUILD_DIR/latest.zip"
    ln -sf "$(basename "$zip_file")" "$BUILD_DIR/$commit_hash.zip"

    log "================================================="
    log "BUILD SUCCEEDED!"
    log "Commit ZIP:    $zip_file"
    log "Short link:    $BUILD_DIR/$commit_hash.zip"
    log "Latest link:   $BUILD_DIR/latest.zip"
    log "Date copy:     $BUILD_DIR/$KERNEL_NAME-$DATE.zip"
    log "Kernel Image:  $BUILD_DIR/Image.gz-dtb"
    log "================================================="
}

case "$ACTION" in
    clean)
        clean_build
        ;;
    distclean)
        distclean_build
        ;;
    menuconfig)
        run_menuconfig
        ;;
    kernel)
        build_kernel
        ;;
    zip|package)
        package_zip
        ;;
    all|"")
        build_kernel
        package_zip
        ;;
    *)
        err "Unknown action: $ACTION"
        echo "Usage: $0 [all|kernel|zip|menuconfig|clean|distclean]"
        exit 1
        ;;
esac
