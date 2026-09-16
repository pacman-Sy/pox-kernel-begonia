#!/usr/bin/env bash
#
# build.sh - Portable MeTh kernel builder & AnyKernel3 flashable zip packager
# For Redmi Note 8 Pro (begonia, MT6785)
#
# Dependencies are fully self-contained inside ./kerdevdep
# Builds and flashable zips are placed in ./build
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/out}"
KERDEVDEP="${KERDEVDEP:-$ROOT_DIR/kerdevdep}"
KERNEL_NAME="${KERNEL_NAME:-Pox-Kernel-begonia}"
DEFCONFIG="${DEFCONFIG:-begonia_apatch_defconfig}"
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

export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-TXO_R}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-PoxKernel}"

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

    # shellcheck disable=SC2086
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

    local commit_hash commit_date commit_subject kver toolchain_ver git_branch
    commit_hash="$(git rev-parse --short HEAD 2>/dev/null || echo "custom")"
    commit_date="$(git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || date +'%Y-%m-%d %H:%M')"
    commit_subject="$(git log -1 --format=%s 2>/dev/null || echo "Release build")"
    git_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "memory-enhanced")"
    kver="4.14.$(grep -m1 '^SUBLEVEL =' "$ROOT_DIR/Makefile" | awk '{print $3}')"
    toolchain_ver="Clang 11.0.1 + GCC 9.3"

    # Generate dynamic changelog ui_print statements for TWRP
    local changelog_ui=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local escaped_line
        escaped_line="$(echo "$line" | sed 's/"/\\"/g')"
        changelog_ui+="ui_print \"   * ${escaped_line}\";\n"
    done < <(git log -n 8 --pretty=format:"[%h] %s" 2>/dev/null || echo "[custom] Initial Pox Kernel release")

    # Generate standalone CHANGELOG.txt for the flashable zip
    {
        echo "========================================================"
        echo " POX KERNEL - Redmi Note 8 Pro (begonia)"
        echo " Maintainer: TXO R"
        echo " Motto: We aim for stability, not for anything else."
        echo " Branch: $git_branch"
        echo " Linux: v$kver | Build: $commit_hash | Date: $commit_date"
        echo " Toolchain: $toolchain_ver"
        echo " Defconfig: $DEFCONFIG (APatch ready)"
        echo " Memory: iOS-Style On-Demand Multi-Stream Compressed ZRAM"
        echo "========================================================"
        echo ""
        echo "--- Changelog (Recent Commits) ---"
        git log -n 15 --pretty=format:"* %h (%cd) - %s%n  Author: %an%n%b" --date=short 2>/dev/null || git log -n 5 2>/dev/null || true
    } > "$stage/CHANGELOG.txt"

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
# begonia (Redmi Note 8 Pro) is an A-only device: a single boot partition,
# no A/B slot suffix. Keep IS_SLOT_DEVICE=0 (AnyKernel3 default for A-only).
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## TWRP / Recovery UI Banner & Version Details
ui_print " ";
ui_print " ============================================";
ui_print "                 POX KERNEL                  ";
ui_print " ============================================";
ui_print "  * Device     : Redmi Note 8 Pro (begonia)  ";
ui_print "  * Maintainer : TXO R                       ";
ui_print "  * Motto      : We aim for stability,       ";
ui_print "                 not for anything else.      ";
ui_print "  * Branch     : $git_branch                 ";
ui_print "  * Linux Ver  : $kver                       ";
ui_print "  * Build Hash : $commit_hash                ";
ui_print "  * Build Date : $commit_date                ";
ui_print "  * Toolchain  : $toolchain_ver              ";
ui_print "  * Features   : APatch / KernelPatch ready  ";
ui_print "  * Mem Engine : iOS-Style On-Demand ZRAM    ";
ui_print "  * Game Engine: Zero Frame-Drop Gaming Mode ";
ui_print "  * Perf Mode  : ROM Performance Auto-Trigger";
ui_print " --------------------------------------------";
ui_print "  LATEST COMMIT:";
ui_print "  $commit_subject";
ui_print " --------------------------------------------";
ui_print "  CHANGELOG (Recent Changes):";
$(printf '%b' "$changelog_ui")
ui_print " ============================================";
ui_print " ";

## AnyKernel file attributes
ui_print " [*] [1/4] Configuring ramdisk permissions & ownership...";
ui_print "     - Target partition: /dev/block/by-name/boot (A-only)";
chmod -R 750 \$RAMDISK/*;
chown -R root:root \$RAMDISK/*;

## AnyKernel install
ui_print " [*] [2/4] Dumping and unpacking current boot image...";
dump_boot;

## Ramdisk enhancements
if [ -d "\$RAMDISK" ]; then
    ui_print " [*] Injecting memory enhancement & gaming mode into ramdisk...";

    # 1. iOS-Style On-Demand Compressed Memory Management
    cat << 'RC_EOF' > \$RAMDISK/init.memory_enhanced.rc
on boot
    # iOS-style On-Demand Compressed Memory Management
    write /proc/sys/vm/watermark_scale_factor 150
    write /proc/sys/vm/page-cluster 0
    write /proc/sys/vm/vfs_cache_pressure 60
    write /proc/sys/vm/swappiness 100
    write /proc/sys/vm/dirty_ratio 15
    write /proc/sys/vm/dirty_background_ratio 5

on property:sys.boot_completed=1
    write /sys/block/zram0/comp_algorithm lz4
    write /proc/sys/vm/watermark_scale_factor 150
    write /proc/sys/vm/page-cluster 0
    write /proc/sys/vm/vfs_cache_pressure 60
    write /proc/sys/vm/swappiness 100
RC_EOF
    chmod 644 \$RAMDISK/init.memory_enhanced.rc

    # 2. Zero Frame-Drop Gaming Mode & ROM Performance Mode Triggers
    cat << 'RC_EOF' > \$RAMDISK/init.gaming.rc
# Gaming Mode Init Script for Redmi Note 8 Pro (begonia)
# Triggers full gaming performance optimizations when Performance Mode / GameSpace is selected in the ROM

on boot
    chmod 0664 /proc/perfmgr/gaming_mode
    chmod 0664 /sys/kernel/gaming_mode
    chmod 0664 /sys/module/ged/parameters/gx_game_mode
    chmod 0664 /sys/module/ged/parameters/gx_boost_on
    chmod 0664 /sys/module/ged/parameters/boost_gpu_enable
    chmod 0664 /sys/module/ged/parameters/gx_force_cpu_boost
    write /sys/module/ged/parameters/boost_gpu_enable 1

# ROM Performance Mode / Game Space Active
on property:persist.sys.power_mode_perf=1
    write /proc/perfmgr/gaming_mode 1
    write /sys/block/sda/queue/read_ahead_kb 512
    write /sys/block/sdb/queue/read_ahead_kb 512
    write /sys/block/sdc/queue/read_ahead_kb 512
    write /sys/block/mmcblk0/queue/read_ahead_kb 512

on property:persist.sys.power_mode_perf=0
    write /proc/perfmgr/gaming_mode 0
    write /sys/block/sda/queue/read_ahead_kb 128
    write /sys/block/sdb/queue/read_ahead_kb 128
    write /sys/block/sdc/queue/read_ahead_kb 128
    write /sys/block/mmcblk0/queue/read_ahead_kb 128

# LineageOS Performance Profile (0=power_save, 1=balanced, 2=performance)
on property:sys.perf.profile=2
    setprop persist.sys.power_mode_perf 1

on property:sys.perf.profile=1
    setprop persist.sys.power_mode_perf 0

on property:sys.perf.profile=0
    setprop persist.sys.power_mode_perf 0

# GameSpace Mode (AOSP / Chaldea GameSpace)
on property:sys.gamespace.mode=1
    setprop persist.sys.power_mode_perf 1

on property:sys.gamespace.mode=0
    setprop persist.sys.power_mode_perf 0

on property:sys.gamespace.in_game=1
    setprop persist.sys.power_mode_perf 1

on property:sys.gamespace.in_game=0
    setprop persist.sys.power_mode_perf 0

# AOSP / PixelOS / LineageOS libperfmgr PowerHAL trigger
on property:vendor.powerhal.state=SUSTAINED_PERFORMANCE
    setprop persist.sys.power_mode_perf 1

on property:vendor.powerhal.state=""
    setprop persist.sys.power_mode_perf 0

# MIUI / HyperOS Performance Mode trigger
on property:persist.sys.perf_mode=1
    setprop persist.sys.power_mode_perf 1

on property:persist.sys.perf_mode=0
    setprop persist.sys.power_mode_perf 0

# Direct debug toggle
on property:debug.gaming.mode=1
    setprop persist.sys.power_mode_perf 1

on property:debug.gaming.mode=0
    setprop persist.sys.power_mode_perf 0
RC_EOF
    chmod 644 \$RAMDISK/init.gaming.rc

    if [ -f "\$RAMDISK/init.rc" ]; then
        insert_line init.rc "init.memory_enhanced.rc" after "import /init.environ.rc" "import /init.memory_enhanced.rc";
        insert_line init.rc "init.gaming.rc" after "import /init.memory_enhanced.rc" "import /init.gaming.rc";
    fi
fi

ui_print " [*] [3/4] Repacking boot image with Pox kernel (Image.gz-dtb)...";
ui_print "     - Linux kernel: v$kver (MT6785 / Helio G90T)";
ui_print "     - Low-battery call reboot fix: active";
ui_print "     - Low-battery lag/throttling fix: active";
ui_print "     - APatch / KernelPatch KALLSYMS: enabled";
ui_print "     - iOS-Style Compressed Memory: watermark=150, cluster=0";
ui_print "     - High-speed ZRAM / ZSWAP compression: active";
ui_print "     - Zero Frame-Drop Gaming Mode: active on ROM Performance toggle";
ui_print "     - FPSGO Ultra-Rescue + Mali-G76 MC4 Touch Boost: enabled";
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
