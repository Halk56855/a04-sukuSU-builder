#!/bin/bash
set -e
set -u
set -o pipefail

# ==============================================================================
# SukiSU-Ultra + SUSFS (Builtin Mode) Kernel Builder for Samsung Galaxy A04
# Kernel Version: 4.19 (mt6765)
# Packaging: AnyKernel3 Zip
# ==============================================================================

WORK_DIR="$(pwd)"
KERNEL_DIR="${WORK_DIR}/kernel"
OUTPUT_DIR="${WORK_DIR}/output"
TOOLCHAIN_DIR="${WORK_DIR}/toolchains"
JOBS=$(nproc --all 2>/dev/null || echo 4)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" >&2; }
err()  { echo -e "${RED}[x]${NC} $1" >&2; exit 1; }

download_kernel_source() {
    [ -f "$KERNEL_DIR/Makefile" ] && return
    log "Cloning Samsung Galaxy A04 kernel source..."
    mkdir -p "$KERNEL_DIR"
    git clone --depth=1 -b latest-B https://github.com/rsuntk-oss/android_kernel_samsung_a04m.git "$KERNEL_DIR" \
        || err "Failed to clone kernel source"
    [ -f "$KERNEL_DIR/Makefile" ] || err "Kernel source clone did not produce a Makefile in $KERNEL_DIR"
}

setup_toolchains() {
    log "Setting up toolchains (Clang & GCC)..."
    mkdir -p "$TOOLCHAIN_DIR"
    cd "$TOOLCHAIN_DIR"
    local MIRROR_BASE=https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains

    if [ ! -f "clang-r383902/bin/clang" ]; then
        mkdir -p clang-r383902
        curl -fL -o clang.tar.gz "${MIRROR_BASE}/clang-r383902b.tar.gz" \
            || err "Failed to download Clang toolchain"
        tar -xzf clang.tar.gz -C clang-r383902 || err "Failed to extract Clang toolchain"
        rm -f clang.tar.gz
        [ -x "clang-r383902/bin/clang" ] || err "Clang binary missing after extraction"
    fi

    if [ ! -f "aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld" ]; then
        curl -fL -o gcc.tar.gz "${MIRROR_BASE}/aarch64-linux-android-4.9.tar.gz" \
            || curl -fL -o gcc.tar.gz "${MIRROR_BASE}/aarch64-linux-android-4.9-Linux-5.4.tar.gz" \
            || err "Failed to download GCC toolchain"
        mkdir -p gcc_temp
        tar -xzf gcc.tar.gz -C gcc_temp || err "Failed to extract GCC toolchain"
        rm -f gcc.tar.gz
        local GCC_BIN_DIR
        GCC_BIN_DIR=$(find gcc_temp -type d -name "bin" -path "*/aarch64-linux-android-4.9/bin" | head -1)
        [ -n "$GCC_BIN_DIR" ] || err "Could not locate GCC bin directory in extracted toolchain"
        mkdir -p aarch64-linux-android-4.9
        cp -r "$(dirname "$GCC_BIN_DIR")"/* aarch64-linux-android-4.9/
        rm -rf gcc_temp
        cd aarch64-linux-android-4.9/bin
        for f in aarch64-linux-android-*; do
            [ -f "$f" ] && [ ! -e "${f/android-/androidkernel-}" ] && ln -sf "$f" "${f/android-/androidkernel-}"
        done
        cd ../..
        [ -e "aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld" ] \
            || err "GCC cross-compiler linker missing after setup"
    fi
}

apply_419_compat_patches() {
    local dir="$1"
    find "$dir" -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/\baccess_ok(/access_ok(0, /g' {} + \
        || err "Failed to apply access_ok compatibility patch in ${dir}"
    find "$dir" -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/MODULE_IMPORT_NS/\/\//g' {} + \
        || err "Failed to apply MODULE_IMPORT_NS compatibility patch in ${dir}"
    find "$dir" -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i 's|#include <linux/pgtable.h>|#include <linux/mm.h>|g' {} + \
        || err "Failed to apply pgtable.h compatibility patch in ${dir}"
}

patch_file_wrapper() {
    local path="$1"
    [ -f "$path" ] || return 0
    log "Patching file_wrapper.c for Kernel 4.19 API..."
    FILE_WRAPPER_PATH="$path" python3 -c '
import os, re, sys
path = os.environ["FILE_WRAPPER_PATH"]
try:
    with open(path, "r") as f:
        code = f.read()

    if "<linux/version.h>" not in code:
        code = "#include <linux/version.h>\n" + code

    code = re.sub(r"(\.iopoll\s*=)", r"// \1", code)
    code = re.sub(r"(\.remap_file_range\s*=)", r"// \1", code)
    code = re.sub(r"(\bREMAP_FILE_DEDUP\b)", r"0", code)
    code = re.sub(r"(\bksu_wrapper_iopoll\b)", r"NULL", code)
    code = re.sub(r"(\bksu_wrapper_remap_file_range\b)", r"NULL", code)

    with open(path, "w") as f:
        f.write(code)
except Exception as e:
    sys.exit(f"Patch error: {e}")
' || err "Failed to patch file_wrapper.c (${path})"
}

integrate_susfs_and_sukisu() {
    log "=== Integrating SUSFS & SukiSU-Ultra ==="
    cd "$WORK_DIR"

    # 1. تحميل رقع SUSFS الرسمية
    if [ ! -d "susfs4ksu" ]; then
        log "Cloning susfs4ksu repository..."
        git clone https://gitlab.com/simonpunk/susfs4ksu.git --depth=1 susfs4ksu
    fi

    cd "$KERNEL_DIR"

    # 2. إصلاح وحدة الاتصال لمعالجات MediaTek
    if [ -d "drivers/misc/mediatek/connectivity" ]; then
        rm -rf drivers/misc/mediatek/connectivity
        git clone --depth=1 https://github.com/rsuntkOrgs/mtk_connectivity_module.git -b staging-4.14 drivers/misc/mediatek/connectivity \
            || err "Failed to clone MediaTek connectivity module (original module was removed)"
        rm -rf drivers/misc/mediatek/connectivity/.git
    fi

    # 3. تنظيف أي مجلد قديم لـ kernelsu
    rm -rf drivers/kernelsu

    # 4. تشغيل أمر الدمج الرسمي لـ SukiSU-Ultra
    log "Running SukiSU-Ultra official setup script..."
    curl -fLSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
    [ -d "drivers/kernelsu" ] || err "SukiSU-Ultra setup did not create drivers/kernelsu"

    # 5. نسخ ملفات الترويسة الخاصة بـ SUSFS إلى مجلد include النواة لحل خطأ susfs_def.h
    log "Copying SUSFS header files to kernel include directory..."
    mkdir -p include/linux
    local SUSFS_INC="${WORK_DIR}/susfs4ksu/kernel_patches/include/linux"
    for h in susfs.h susfs_def.h; do
        if [ -f "${SUSFS_INC}/${h}" ]; then
            cp -f "${SUSFS_INC}/${h}" include/linux/ || err "Failed to copy SUSFS header ${h}"
        else
            warn "SUSFS header ${h} not found at ${SUSFS_INC}; skipping"
        fi
    done

    # 6. تطبيق رقع SUSFS على النواة إذا توفرت الرقعة المناسبة للإصدار 4.19
    local SUSFS_PATCH="${WORK_DIR}/susfs4ksu/kernel_patches/50_add_susfs_in_v4.19.patch"
    if [ -f "$SUSFS_PATCH" ]; then
        log "Applying SUSFS patch for Kernel 4.19..."
        patch -p1 < "$SUSFS_PATCH" || err "Failed to apply SUSFS patch for Kernel 4.19"
    else
        warn "SUSFS 4.19 patch not found at ${SUSFS_PATCH}; skipping"
    fi

    # 7. إصلاحات التوافقية لنواة Linux 4.19
    log "Applying Kernel 4.19 compatibility patches..."
    apply_419_compat_patches drivers/kernelsu

    # 8. معالجة ملف file_wrapper.c لنواة 4.19
    patch_file_wrapper "drivers/kernelsu/infra/file_wrapper.c"
}

configure_kernel() {
    log "Configuring kernel build options..."
    cd "$KERNEL_DIR"
    export ARCH=arm64
    export CROSS_COMPILE="${TOOLCHAIN_DIR}/aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-"
    export CC="${TOOLCHAIN_DIR}/clang-r383902/bin/clang"
    export CLANG_TRIPLE="aarch64-linux-gnu-"

    local MAKE_OPTS=( -C "$(pwd)" O="$(pwd)/out" KCFLAGS=-w CONFIG_SECTION_MISMATCH_WARN_ONLY=y ARCH=arm64 CC="${CC}" CLANG_TRIPLE="${CLANG_TRIPLE}" CROSS_COMPILE="${CROSS_COMPILE}" )

    make "${MAKE_OPTS[@]}" a04_defconfig

    # تفعيل الخيارات المطلوبة
    scripts/config --file out/.config --enable CONFIG_KSU
    scripts/config --file out/.config --enable CONFIG_KPM
    scripts/config --file out/.config --enable CONFIG_KALLSYMS
    scripts/config --file out/.config --enable CONFIG_KALLSYMS_ALL
    scripts/config --file out/.config --enable CONFIG_OVERLAY_FS
    scripts/config --file out/.config --enable CONFIG_KSU_SUSFS || true

    # تعطيل حماية سامسونج
    for opt in SECURITY_DEFEX PROCA FIVE UH RKP_KDP SEC_RESTRICT_ROOTING SEC_RESTRICT_SETUID SEC_RESTRICT_FORK SEC_RESTRICT_ROOTING_LOG KNOX_KAP TIMA TIMA_LKMAUTH TIMA_LKM_BLOCK TIMA_LKMAUTH_CODE_PROT INTEGRITY INTEGRITY_SIGNATURE INTEGRITY_ASYMMETRIC_KEYS INTEGRITY_TRUSTED_KEYRING INTEGRITY_AUDIT DM_VERITY; do
        scripts/config --file out/.config --disable "CONFIG_${opt}" 2>/dev/null || true
    done

    scripts/config --file out/.config --enable CONFIG_SECURITY_SELINUX_DEVELOP || true
    scripts/config --file out/.config --disable CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE || true
    scripts/config --file out/.config --set-str CONFIG_LOCALVERSION "-SukiSU-SUSFS-A04"
    scripts/config --file out/.config --disable CONFIG_LOCALVERSION_AUTO

    make "${MAKE_OPTS[@]}" olddefconfig || err "Failed to finalize kernel config (olddefconfig)"
}

build_kernel() {
    log "Building kernel with ${JOBS} threads..."
    cd "$KERNEL_DIR"
    local MAKE_OPTS=( -C "$(pwd)" O="$(pwd)/out" KCFLAGS=-w CONFIG_SECTION_MISMATCH_WARN_ONLY=y ARCH=arm64 CC="${CC}" CLANG_TRIPLE="${CLANG_TRIPLE}" CROSS_COMPILE="${CROSS_COMPILE}" )

    make "${MAKE_OPTS[@]}" -j"${JOBS}" 2>&1 | tee "${OUTPUT_DIR}/build.log" || make "${MAKE_OPTS[@]}" -j1 2>&1 | tee -a "${OUTPUT_DIR}/build.log"
    if [ -f "out/arch/arm64/boot/Image" ]; then
        cp "out/arch/arm64/boot/Image" "arch/arm64/boot/Image" || err "Failed to copy built kernel Image"
    else
        err "Kernel Image build failed!"
    fi
}

package_kernel() {
    log "Packaging AnyKernel3 zip..."
    mkdir -p "$OUTPUT_DIR"
    cd "$WORK_DIR"
    rm -rf AnyKernel3
    git clone https://github.com/osm0sis/AnyKernel3.git --depth=1 AnyKernel3 \
        || err "Failed to clone AnyKernel3"

    local img_copied=0
    for img in "out/arch/arm64/boot/Image.gz-dtb" "out/arch/arm64/boot/Image.gz" "out/arch/arm64/boot/Image"; do
        if [ -f "${KERNEL_DIR}/${img}" ]; then
            cp "${KERNEL_DIR}/${img}" AnyKernel3/ || err "Failed to copy ${img} into AnyKernel3"
            img_copied=1
            break
        fi
    done
    [ "$img_copied" -eq 1 ] || err "No kernel image found to package"

    cd AnyKernel3
    sed -i 's/block=auto/block=\/dev\/block\/by-name\/boot/g' anykernel.sh \
        || err "Failed to configure anykernel.sh (block)"
    sed -i 's/is_slot_device=1/is_slot_device=0/g' anykernel.sh \
        || err "Failed to configure anykernel.sh (is_slot_device)"

    ZIP_NAME="SukiSU-SUSFS-A04-Kernel.zip"
    # shellcheck disable=SC2035  # intentional glob of packaging contents and exclude patterns
    zip -r9 "${OUTPUT_DIR}/${ZIP_NAME}" * -x .git README.md *placeholder \
        || err "Failed to create AnyKernel3 zip package"
    log "Created package: ${OUTPUT_DIR}/${ZIP_NAME}"
}

main() {
    mkdir -p "$OUTPUT_DIR"
    download_kernel_source
    setup_toolchains
    integrate_susfs_and_sukisu
    configure_kernel
    build_kernel
    package_kernel
}

# Only run when executed directly, so the functions can be sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
