#!/bin/bash
set -e
set -u
set -o pipefail

# ==============================================================================
# SukiSU-Ultra + SUSFS Kernel Builder for Samsung Galaxy A04 (SM-A045F)
# Target: Kernel 4.19 (mt6765)
# Packaging: AnyKernel3 Zip
# ==============================================================================

WORK_DIR="$(pwd)"
KERNEL_DIR="${WORK_DIR}/kernel"
OUTPUT_DIR="${WORK_DIR}/output"
TOOLCHAIN_DIR="${WORK_DIR}/toolchains"
SUSFS_DIR="${WORK_DIR}/susfs"
JOBS=$(nproc --all 2>/dev/null || echo 4)

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

encoded_src() {
  local src="$1"
  local out=""
  local ch
  local i=0
  while [ $i -lt ${#src} ]; do
    ch=$(printf '%s' "$src" | cut -c$((i+1)))
    case "$ch" in
      [a-zA-Z0-9]) out="${out}${ch}" ;;
      *) out="${out}$(printf '%%%02X' "'${ch}")" ;;
    esac
    i=$((i+1))
  done
  printf '%s' "$out"
}

download_kernel_source() {
    if [ -f "$KERNEL_DIR/Makefile" ]; then
        log "Kernel source exists at $KERNEL_DIR"
        return
    fi
    log "Cloning Samsung Galaxy A04 kernel source..."
    mkdir -p "$KERNEL_DIR"
    git clone --depth=1 -b latest-B \
        https://github.com/rsuntk-oss/android_kernel_samsung_a04m.git \
        "$KERNEL_DIR" || err "Failed to clone kernel source"
}

setup_toolchains() {
    log "Setting up toolchains (Clang & GCC)..."
    mkdir -p "$TOOLCHAIN_DIR"
    cd "$TOOLCHAIN_DIR"

    local MIRROR_BASE=https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains

    if [ ! -f "clang-r383902/bin/clang" ]; then
        log "Downloading Clang r383902b..."
        mkdir -p clang-r383902
        curl -L -o clang.tar.gz --connect-timeout 30 --retry 3 \
            "${MIRROR_BASE}/clang-r383902b.tar.gz" || err "Failed to download Clang"
        tar -xzf clang.tar.gz -C clang-r383902 2>/dev/null || err "Failed to extract Clang"
        rm -f clang.tar.gz
    fi

    if [ ! -f "aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld" ]; then
        log "Downloading GCC 4.9 toolchain..."
        curl -L -o gcc.tar.gz --connect-timeout 30 --retry 3 \
            "${MIRROR_BASE}/aarch64-linux-android-4.9.tar.gz" || \
            curl -L -o gcc.tar.gz --connect-timeout 30 --retry 3 \
            "${MIRROR_BASE}/aarch64-linux-android-4.9-Linux-5.4.tar.gz" || \
            err "Failed to download GCC"

        mkdir -p gcc_temp
        tar -xzf gcc.tar.gz -C gcc_temp 2>/dev/null || err "Failed to extract GCC"
        rm -f gcc.tar.gz

        local GCC_BIN_DIR=$(find gcc_temp -type d -name "bin" -path "*/aarch64-linux-android-4.9/bin" | head -1)
        [ -z "$GCC_BIN_DIR" ] && err "Could not find GCC bin directory"
        mkdir -p aarch64-linux-android-4.9
        cp -r "$(dirname "$GCC_BIN_DIR")"/* aarch64-linux-android-4.9/
        rm -rf gcc_temp

        cd aarch64-linux-android-4.9/bin
        for f in aarch64-linux-android-*; do
            [ -f "$f" ] && [ ! -e "${f/android-/androidkernel-}" ] && ln -sf "$f" "${f/android-/androidkernel-}"
        done
        cd ../..
    fi
}

integrate_susfs_sukisu() {
    log "=== Integrating SUSFS + SukiSU-Ultra ==="
    cd "$KERNEL_DIR"

    # 1. Download SUSFS Patches
    mkdir -p "$SUSFS_DIR"
    cd "$SUSFS_DIR"
    local GITLAB_API="https://gitlab.com/api/v4/projects/simonpunk%2Fsusfs4ksu/repository"
    local SUSFS_REF="kernel-4.19"

    curl -L --connect-timeout 30 --retry 3 \
        "${GITLAB_API}/files/kernel_patches%2F50_add_susfs_in_kernel-4.19.patch/raw?ref=${SUSFS_REF}" \
        -o "50_add_susfs_in_kernel-4.19.patch" || true

    local SUSFS_FILES=(
        "kernel_patches/fs/susfs.c:fs/susfs.c"
        "kernel_patches/fs/sus_su.c:fs/sus_su.c"
        "kernel_patches/include/linux/susfs.h:include/linux/susfs.h"
        "kernel_patches/include/linux/susfs_def.h:include/linux/susfs_def.h"
    )
    for entry in "${SUSFS_FILES[@]}"; do
        local src="${entry%%:*}"
        local dst="${entry#*:}"
        mkdir -p "$(dirname "$dst")"
        local encoded=$(encoded_src "$src")
        curl -L --connect-timeout 30 --retry 3 \
            "${GITLAB_API}/files/${encoded}/raw?ref=${SUSFS_REF}" \
            -o "$dst" || true
    done

    cd "$KERNEL_DIR"

    # 2. Apply SUSFS Patches
    if [ -f "${SUSFS_DIR}/50_add_susfs_in_kernel-4.19.patch" ]; then
        log "Applying SUSFS patch..."
        patch -p1 --forward --fuzz=3 --no-backup-if-mismatch \
            < "${SUSFS_DIR}/50_add_susfs_in_kernel-4.19.patch" 2>&1 || true

        if [ -f fs/notify/fdinfo.c ]; then
            sed -i 's/out_seq_printf:/out_seq_printf:;/g' fs/notify/fdinfo.c
            grep -q "inotify_mark_user_mask" fs/notify/fdinfo.c && \
            ! grep -q "#define inotify_mark_user_mask" fs/notify/fdinfo.c && \
            sed -i '/#include <linux\/exportfs.h>/a #define inotify_mark_user_mask(mark) (mark->mask \& IN_ALL_EVENTS)' fs/notify/fdinfo.c
        fi
    fi

    [ -f "${SUSFS_DIR}/fs/susfs.c" ] && cp "${SUSFS_DIR}/fs/susfs.c" "fs/susfs.c" && chmod 644 "fs/susfs.c"
    [ -f "${SUSFS_DIR}/fs/sus_su.c" ] && cp "${SUSFS_DIR}/fs/sus_su.c" "fs/sus_su.c" && chmod 644 "fs/sus_su.c"
    [ -f "${SUSFS_DIR}/include/linux/susfs.h" ] && cp "${SUSFS_DIR}/include/linux/susfs.h" "include/linux/susfs.h" && chmod 644 "include/linux/susfs.h"
    [ -f "${SUSFS_DIR}/include/linux/susfs_def.h" ] && cp "${SUSFS_DIR}/include/linux/susfs_def.h" "include/linux/susfs_def.h" && chmod 644 "include/linux/susfs_def.h"

    grep -q "susfs.o" "fs/Makefile" || sed -i '/^obj-y :=.*nsfs.o/a obj-$(CONFIG_KSU_SUSFS) += susfs.o' "fs/Makefile" 2>/dev/null || true

    # 3. MediaTek Connectivity Fix
    if [ -d "drivers/misc/mediatek/connectivity" ]; then
        rm -rf drivers/misc/mediatek/connectivity
        git clone --depth=1 https://github.com/rsuntkOrgs/mtk_connectivity_module.git \
            -b staging-4.14 drivers/misc/mediatek/connectivity 2>/dev/null || true
        rm -rf drivers/misc/mediatek/connectivity/.git
    fi

    # 4. Fetch SukiSU-Ultra
    log "Cloning SukiSU-Ultra..."
    rm -rf drivers/kernelsu
    git clone --recursive https://github.com/SukiSU-Ultra/SukiSU-Ultra drivers/kernelsu --depth=1
    [ -d "drivers/kernelsu/kernel" ] && cp -r drivers/kernelsu/kernel/* drivers/kernelsu/ || true

    # 5. Compatibility Patches for Kernel 4.19
    log "Applying Kernel 4.19 compatibility patches..."
    find drivers/kernelsu -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/\baccess_ok(/access_ok(0, /g' {} + || true
    find drivers/kernelsu -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/MODULE_IMPORT_NS/\/\//g' {} + || true
    find drivers/kernelsu -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's|#include <linux/pgtable.h>|#include <linux/mm.h>|g' {} + || true

    # 6. Safe patch for file_wrapper.c without breaking C syntax
    if [ -f "drivers/kernelsu/infra/file_wrapper.c" ]; then
        log "Fixing file_wrapper.c for Kernel 4.19 safely..."
        python3 -c '
import re

path = "drivers/kernelsu/infra/file_wrapper.c"
try:
    with open(path, "r") as f:
        code = f.read()

    if "<linux/version.h>" not in code:
        code = "#include <linux/version.h>\n" + code

    # Comment out unneeded functions safely using C comments
    code = re.sub(r"(\bksu_wrapper_remap_file_range\b)", r"/* \1 */ dummy_remap_range", code)
    code = re.sub(r"(\bksu_wrapper_iopoll\b)", r"/* \1 */ dummy_iopoll", code)

    with open(path, "w") as f:
        f.write(code)
    print("file_wrapper.c patched successfully.")
except Exception as e:
    print("Error patching file_wrapper.c:", e)
' || true
    fi

    # 7. Register SukiSU in Makefile & Kconfig
    grep -q "kernelsu" drivers/Makefile || echo 'obj-y += kernelsu/' >> drivers/Makefile
    grep -q "kernelsu" drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
}

configure_kernel() {
    log "Configuring kernel build options..."
    cd "$KERNEL_DIR"
    export ARCH=arm64
    export CROSS_COMPILE="${TOOLCHAIN_DIR}/aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-"
    export CC="${TOOLCHAIN_DIR}/clang-r383902/bin/clang"
    export CLANG_TRIPLE="aarch64-linux-gnu-"

    local MAKE_OPTS=( -C "$(pwd)" O="$(pwd)/out" KCFLAGS=-w CONFIG_SECTION_MISMATCH_WARN_ONLY=y ARCH=arm64 CC="${CC}" CLANG_TRIPLE="${CLANG_TRIPLE}" CROSS_COMPILE="${CROSS_COMPILE}" )

    make "${MAKE_OPTS[@]}" a04_defconfig || err "Defconfig failed"

    # Enable KSU & SUSFS
    scripts/config --file out/.config --enable CONFIG_KSU
    scripts/config --file out/.config --enable CONFIG_KPM
    scripts/config --file out/.config --enable CONFIG_KALLSYMS
    scripts/config --file out/.config --enable CONFIG_KALLSYMS_ALL
    scripts/config --file out/.config --enable CONFIG_OVERLAY_FS

    for opt in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_SU SPOOF_UNAME KSU_SUSFS_ENFORCE_SUSFS KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS KSU_SUSFS_SUS_OVERLAYFS; do
        scripts/config --file out/.config --enable "CONFIG_${opt}" 2>/dev/null || true
    done

    # Disable Samsung Security features interfering with Root
    for opt in SECURITY_DEFEX PROCA FIVE UH RKP_KDP SEC_RESTRICT_ROOTING SEC_RESTRICT_SETUID SEC_RESTRICT_FORK SEC_RESTRICT_ROOTING_LOG KNOX_KAP TIMA TIMA_LKMAUTH TIMA_LKM_BLOCK TIMA_LKMAUTH_CODE_PROT INTEGRITY INTEGRITY_SIGNATURE INTEGRITY_ASYMMETRIC_KEYS INTEGRITY_TRUSTED_KEYRING INTEGRITY_AUDIT DM_VERITY; do
        scripts/config --file out/.config --disable "CONFIG_${opt}" 2>/dev/null || true
    done

    scripts/config --file out/.config --enable CONFIG_SECURITY_SELINUX_DEVELOP || true
    scripts/config --file out/.config --disable CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE || true
    scripts/config --file out/.config --set-str CONFIG_LOCALVERSION "-TragicHorizon-v3-r1"
    scripts/config --file out/.config --disable CONFIG_LOCALVERSION_AUTO

    make "${MAKE_OPTS[@]}" olddefconfig 2>/dev/null || true
}

build_kernel() {
    log "Building kernel with ${JOBS} threads..."
    cd "$KERNEL_DIR"
    local MAKE_OPTS=( -C "$(pwd)" O="$(pwd)/out" KCFLAGS=-w CONFIG_SECTION_MISMATCH_WARN_ONLY=y ARCH=arm64 CC="${CC}" CLANG_TRIPLE="${CLANG_TRIPLE}" CROSS_COMPILE="${CROSS_COMPILE}" )

    if ! make "${MAKE_OPTS[@]}" -j"${JOBS}" 2>&1 | tee "${OUTPUT_DIR}/build.log"; then
        warn "Parallel build failed, trying single thread for detailed output..."
        make "${MAKE_OPTS[@]}" -j1 2>&1 | tee -a "${OUTPUT_DIR}/build.log" || {
            tail -n 60 "${OUTPUT_DIR}/build.log"
            err "Kernel compilation failed!"
        }
    fi

    [ -f "out/arch/arm64/boot/Image" ] && cp "out/arch/arm64/boot/Image" "arch/arm64/boot/Image" || err "Image file missing!"
}

package_kernel() {
    log "Packaging AnyKernel3 zip..."
    mkdir -p "$OUTPUT_DIR"
    cd "$WORK_DIR"
    rm -rf AnyKernel3
    git clone https://github.com/osm0sis/AnyKernel3.git --depth=1 AnyKernel3

    for img in "out/arch/arm64/boot/Image.gz-dtb" "out/arch/arm64/boot/Image.gz" "out/arch/arm64/boot/Image"; do
        [ -f "${KERNEL_DIR}/${img}" ] && cp "${KERNEL_DIR}/${img}" AnyKernel3/ && break
    done

    cd AnyKernel3
    sed -i 's/block=auto/block=\/dev\/block\/by-name\/boot/g' anykernel.sh || true
    sed -i 's/is_slot_device=1/is_slot_device=0/g' anykernel.sh || true

    ZIP_NAME="TragicHorizon-v3-r1-A04-AnyKernel3.zip"
    zip -r9 "${OUTPUT_DIR}/${ZIP_NAME}" * -x .git README.md *placeholder
    log "Successfully generated package: ${OUTPUT_DIR}/${ZIP_NAME}"
}

main() {
    mkdir -p "$OUTPUT_DIR"
    download_kernel_source
    setup_toolchains
    integrate_susfs_sukisu
    configure_kernel
    build_kernel
    package_kernel
}

main "$@"
