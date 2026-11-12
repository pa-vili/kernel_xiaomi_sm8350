#!/usr/bin/env bash
#
# Kernel Build & Prebuilt Deploy Script for Xiaomi 11T Pro (vili / SM8350)
# Target: AOSPA Calcite / Android 14+
# Features: 5.10 Version Spoof, -O3, Clang ThinLTO, BOLT relocations, Auto-Toolchain Setup, Prebuilt Repo Sync & Push
#

set -e

# Configuration
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$HOME/toolchains/neutron-clang}"
OUT_DIR="${KERNEL_DIR}/out"
JOBS="${JOBS:-20}"
TARGET_PRODUCT="vili"
BRANCH="calcite"

# Prebuilt destination detection
if [ -n "${PREBUILT_DIR}" ] && [ -d "${PREBUILT_DIR}" ]; then
    DEST_DIR="${PREBUILT_DIR}"
elif [ -d "${KERNEL_DIR}/../device_xiaomi_vili-kernel" ]; then
    DEST_DIR="$(cd "${KERNEL_DIR}/../device_xiaomi_vili-kernel" && pwd)"
elif [ -d "${KERNEL_DIR}/../../device/xiaomi/vili-kernel" ]; then
    DEST_DIR="$(cd "${KERNEL_DIR}/../../device/xiaomi/vili-kernel" && pwd)"
elif [ -d "${KERNEL_DIR}/../vili-kernel" ]; then
    DEST_DIR="$(cd "${KERNEL_DIR}/../vili-kernel" && pwd)"
else
    DEST_DIR=""
fi

echo "=========================================================="
echo " Starting SM8350 Kernel Build for Xiaomi 11T Pro (vili)   "
echo "=========================================================="
echo " Kernel Dir    : ${KERNEL_DIR}"
echo " Out Dir       : ${OUT_DIR}"
echo " Toolchain Dir : ${TOOLCHAIN_DIR}"
echo " Prebuilt Dir  : ${DEST_DIR:-Not configured}"
echo " Jobs          : ${JOBS}"
echo "=========================================================="

# 1. Toolchain Setup (Neutron Clang)
if [ ! -f "${TOOLCHAIN_DIR}/bin/clang" ]; then
    echo ">> Neutron Clang not found in ${TOOLCHAIN_DIR}. Downloading via Antman..."
    mkdir -p "${TOOLCHAIN_DIR}"
    cd "${TOOLCHAIN_DIR}"
    curl -sSLo antman "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
    chmod +x antman
    bash antman -S
    bash antman --patch-glibc || true
    cd "${KERNEL_DIR}"
fi

export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
STRIP="${TOOLCHAIN_DIR}/bin/llvm-strip"

CLANG_VERSION=$("${TOOLCHAIN_DIR}/bin/clang" --version | head -n 1)
echo ">> Using Compiler: ${CLANG_VERSION}"

# Check cross compiler / host tools
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-

# 2. Defconfig Generation
echo ">> Generating kernel configuration..."
mkdir -p "${OUT_DIR}"
make -C "${KERNEL_DIR}" O="${OUT_DIR}" \
    ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    vendor/lahaina-qgki_defconfig \
    vendor/debugfs.config \
    vendor/xiaomi_QGKI.config \
    vendor/vili_QGKI.config

# Verify key configurations
echo ">> Verifying kernel optimizations..."
grep -E "CONFIG_LTO_CLANG|CONFIG_THINLTO|CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE" "${OUT_DIR}/.config" || true

# 3. Kernel Compilation
echo ">> Compiling Image, dtbs, and modules (using -j${JOBS})..."
make -C "${KERNEL_DIR}" O="${OUT_DIR}" \
    ARCH=arm64 \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT}" \
    LLVM=1 LLVM_IAS=1 \
    TARGET_PRODUCT="${TARGET_PRODUCT}" \
    KCFLAGS="-Wno-error" \
    -j"${JOBS}" \
    Image dtbs modules

echo ">> Installing kernel headers..."
make -C "${KERNEL_DIR}" O="${OUT_DIR}" \
    ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    headers_install -j"${JOBS}"

echo ">> Kernel build completed successfully!"

# 4. Copy to Prebuilt Repository
if [ -n "${DEST_DIR}" ] && [ -d "${DEST_DIR}" ]; then
    echo ">> Deploying artifacts to prebuilt repository: ${DEST_DIR}"

    # Copy kernel Image
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        cp -v "${OUT_DIR}/arch/arm64/boot/Image" "${DEST_DIR}/Image"
    fi

    # Copy build metadata
    cp -v "${OUT_DIR}/.config" "${DEST_DIR}/.config" 2>/dev/null || true
    cp -v "${OUT_DIR}/System.map" "${DEST_DIR}/System.map" 2>/dev/null || true
    cp -v "${OUT_DIR}/Module.symvers" "${DEST_DIR}/Module.symvers" 2>/dev/null || true

    # Copy DTBs
    mkdir -p "${DEST_DIR}/dtbs"
    cp -v "${OUT_DIR}"/arch/arm64/boot/dts/vendor/qcom/lahaina*.dtb "${DEST_DIR}/dtbs/" 2>/dev/null || true
    cp -v "${OUT_DIR}"/arch/arm64/boot/dts/vendor/qcom/shima.dtb "${DEST_DIR}/dtbs/" 2>/dev/null || true
    cp -v "${OUT_DIR}"/arch/arm64/boot/dts/vendor/qcom/yupik*.dtb "${DEST_DIR}/dtbs/" 2>/dev/null || true

    # Deploy stripped vendor modules
    echo ">> Updating and stripping vendor modules..."
    DLKM_DEST="${DEST_DIR}/vendor_dlkm"
    RAMDISK_DEST="${DEST_DIR}/vendor_ramdisk"

    find "${OUT_DIR}" -name "*.ko" | while read -r ko; do
        name=$(basename "${ko}")
        if [ -d "${DLKM_DEST}" ] && [ -f "${DLKM_DEST}/${name}" ]; then
            cp "${ko}" "${DLKM_DEST}/${name}"
            "${STRIP}" --strip-debug "${DLKM_DEST}/${name}"
            echo "   Updated dlkm: ${name}"
        fi
        if [ -d "${RAMDISK_DEST}" ] && [ -f "${RAMDISK_DEST}/${name}" ]; then
            cp "${ko}" "${RAMDISK_DEST}/${name}"
            "${STRIP}" --strip-debug "${RAMDISK_DEST}/${name}"
            echo "   Updated ramdisk: ${name}"
        fi
    done

    # 5. Git Commit & Push
    if [ "$1" == "--push" ] || [ "${PUSH_PREBUILT}" == "1" ]; then
        echo ">> Committing and pushing to prebuilt repository..."
        cd "${DEST_DIR}"
        git add -A
        KERNEL_VER=$(cat "${DEST_DIR}/.config" | grep "Linux/" | head -n 1 || echo "5.10.239")
        git commit -m "vili-kernel: Update prebuilt kernel (5.10 string, -O3, LTO, BOLT)

- Kernel version: 5.10.239 spoof for Android 25Q4 NetBpfLoad
- Optimizations: -O3, Clang ThinLTO, BOLT relocations (--emit-relocs)
- Updated Image, DTBs, System.map, Module.symvers, and stripped modules
- Built with Neutron Clang 24" || echo "No changes to commit."

        REMOTE=$(git remote | head -n 1)
        if [ -n "${REMOTE}" ]; then
            git push "${REMOTE}" "${BRANCH}" || git push origin "${BRANCH}"
            echo ">> Prebuilt repository pushed successfully!"
        fi
        cd "${KERNEL_DIR}"
    fi

    echo "=========================================================="
    echo " Deployment completed successfully!                       "
    echo "=========================================================="
else
    echo ">> No prebuilt directory found or configured. Artifacts remain in ${OUT_DIR}."
fi
