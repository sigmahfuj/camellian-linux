#!/usr/bin/env bash
# =============================================================================
# build-kernel.sh -- Build Camellian Kernel (Linux 4.14.186 ARM64)
#
# Local / Ubuntu 22.04 version of .github/workflows/build-kernel.yml
# Every workflow step is kept, in the same order:
#   Checkout Kernel -> Install Dependencies -> Checkout AOSP Clang R383902
#   -> Checkout Android GCC 4.9 -> Setup Toolchains -> Verify Source
#   -> Build Kernel -> Upload Kernel Artifacts
#
# Run from inside the kernel source directory:
#   bash build-kernel.sh
#   bash build-kernel.sh camellian_gl_defconfig
#   DEFCONFIG=camellian_id_defconfig bash build-kernel.sh
#
# Optional:
#   BUILD_TIMEOUT_MIN=180
# =============================================================================

set -Eeuo pipefail
trap 'rc=$?; echo "[ERROR] line ${LINENO}: "${BASH_COMMAND}" exited with status ${rc}" >&2' ERR

step() { printf '\n==================== %s ====================\n' "$*"; }
info() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

ask() {
    local prompt="$1" default="${2-}"
    printf '%s' "$prompt" >&2
    IFS= read -r REPLY || REPLY=""
    REPLY="${REPLY:-$default}"
}

# -----------------------------------------------------------------------------
# Workflow environment
# -----------------------------------------------------------------------------
KERNEL_DIR="$(pwd)"
WORKSPACE="$KERNEL_DIR"

export ARCH=arm64
export CLANG_VERSION=clang-r383902
BUILD_TIMEOUT_MIN="${BUILD_TIMEOUT_MIN:-180}"

CFG_DIR="arch/arm64/configs"

# Build the menu from actual files in CFG_DIR: Camellian only, no debug.
mapfile -t DEFCONFIG_OPTIONS < <(
    find "$CFG_DIR" -maxdepth 1 -type f -name '*_defconfig' -printf '%f\n' \
        | grep -i 'camellian' \
        | grep -iv 'debug' \
        | sort
)

# Keep camellian_defconfig as the default (first) entry if present.
if printf '%s\n' "${DEFCONFIG_OPTIONS[@]}" | grep -qx 'camellian_defconfig'; then
    _reordered=(camellian_defconfig)
    for _c in "${DEFCONFIG_OPTIONS[@]}"; do
        [ "$_c" = "camellian_defconfig" ] && continue
        _reordered+=("$_c")
    done
    DEFCONFIG_OPTIONS=("${_reordered[@]}")
    unset _reordered _c
fi

CUSTOM_INDEX=$(( ${#DEFCONFIG_OPTIONS[@]} + 1 ))

# -----------------------------------------------------------------------------
# Custom defconfig
# -----------------------------------------------------------------------------
ask_custom_defconfig() {
    local name tries
    for tries in 1 2 3; do
        ask "Custom defconfig name (file in $CFG_DIR): " ""
        name="$(basename -- "$REPLY")"
        [ -n "$name" ] || die "No defconfig name given."
        if [ -f "$CFG_DIR/$name" ]; then
            DEFCONFIG="$name"
            info "Using $CFG_DIR/$DEFCONFIG"
            return 0
        elif [ -f "$CFG_DIR/${name}_defconfig" ]; then
            DEFCONFIG="${name}_defconfig"
            info "Using $CFG_DIR/$DEFCONFIG"
            return 0
        fi
        warn "Not found: $CFG_DIR/$name"
    done
    die "Custom defconfig not found."
}

# -----------------------------------------------------------------------------
# Interactive defconfig menu
# -----------------------------------------------------------------------------
choose_defconfig() {
    local i choice
    {
        echo "Select Camellian defconfig:"
        for i in "${!DEFCONFIG_OPTIONS[@]}"; do
            if [ "$i" -eq 0 ]; then
                printf ' %d) %s (default)\n' \
                    $((i + 1)) "${DEFCONFIG_OPTIONS[$i]}"
            else
                printf ' %d) %s\n' \
                    $((i + 1)) "${DEFCONFIG_OPTIONS[$i]}"
            fi
        done
        printf ' %d) Custom defconfig\n' "$CUSTOM_INDEX"
    } >&2

    while true; do
        ask "Choice [1]: " 1
        choice="$REPLY"
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            choice=$((10#$choice))
            if [ "$choice" -ge 1 ] && [ "$choice" -le "$CUSTOM_INDEX" ]; then
                break
            fi
        fi
        warn "Invalid choice: $REPLY"
    done

    if [ "$choice" -eq "$CUSTOM_INDEX" ]; then
        ask_custom_defconfig
    else
        DEFCONFIG="${DEFCONFIG_OPTIONS[$((choice - 1))]}"
    fi
}

# =============================================================================
# Step: Checkout Kernel
# =============================================================================
step "Checkout Kernel"

[ -f Makefile ] && [ -d "$CFG_DIR" ] && grep -q '^VERSION' Makefile || die "Run from kernel source root."
info "Kernel source: $KERNEL_DIR"

DEFCONFIG="${1:-${DEFCONFIG:-}}"
if [ -z "$DEFCONFIG" ]; then
    choose_defconfig
fi
export DEFCONFIG
info "DEFCONFIG = $DEFCONFIG"

# -----------------------------------------------------------------------------
# Environment sanity
# -----------------------------------------------------------------------------
info "Recommended OS: Ubuntu 22.04 or 24.04 (x86_64)."

[ "$(uname -m)" = "x86_64" ] || die "Prebuilt toolchains require x86_64."

if [ -f .config ] || [ -d include/config ]; then
    warn "Existing source config detected."
    warn "O=out builds use the out directory."
fi

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# =============================================================================
# Step: Install Dependencies
# =============================================================================
step "Install Dependencies"

$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bc bison build-essential ccache \
    curl flex git libelf-dev libssl-dev \
    libncurses-dev lld make \
    python3 rsync unzip zip \
    device-tree-compiler \
    gcc g++ liblz4-tool

# =============================================================================
# Step: Checkout AOSP Clang R383902
# =============================================================================
step "Checkout AOSP Clang R383902"

CLANG_REPO="https://github.com/msft-mirror-aosp/platform.prebuilts.clang.host.linux-x86.git"
CLANG_REF="4114ce222c83ba93e9c12c91c6ced2541b28f88c"
CLANG_SRC="$WORKSPACE/toolchain-src/clang"

if [ -e "$CLANG_SRC/clang-r383902/bin/ld.lld" ]; then
    info "Clang source already present."
else
    rm -rf "$CLANG_SRC"
    mkdir -p "$CLANG_SRC"
    git -C "$CLANG_SRC" init -q
    git -C "$CLANG_SRC" remote add origin "$CLANG_REPO"
    git -C "$CLANG_SRC" sparse-checkout init --cone
    git -C "$CLANG_SRC" sparse-checkout set clang-r383902
    git -C "$CLANG_SRC" fetch --depth=1 --filter=blob:none origin "$CLANG_REF"
    git -C "$CLANG_SRC" \
        -c advice.detachedHead=false checkout --detach FETCH_HEAD
fi

# =============================================================================
# Step: Checkout Android GCC 4.9
# =============================================================================
step "Checkout Android GCC 4.9"

GCC_REPO="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git"
GCC_SRC="$WORKSPACE/toolchain-src/gcc"

if [ -e "$GCC_SRC/bin/aarch64-linux-androidkernel-gcc" ]; then
    info "GCC source already present."
else
    rm -rf "$GCC_SRC"
    git clone --depth 1 \
        --branch lineage-19.1 \
        "$GCC_REPO" "$GCC_SRC"
fi

# =============================================================================
# Step: Setup Toolchains
# =============================================================================
step "Setup Toolchains"

cd "$WORKSPACE"
mkdir -p prebuilts/clang/host/linux-x86
mkdir -p prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9

if [ ! -e prebuilts/clang/host/linux-x86/clang-r383902/bin/ld.lld ]; then
    cp -a toolchain-src/clang/clang-r383902 \
        prebuilts/clang/host/linux-x86/
fi

if [ ! -e prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-gcc ]; then
    cp -a toolchain-src/gcc/. \
        prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/
fi

CLANG_BIN="$WORKSPACE/prebuilts/clang/host/linux-x86/clang-r383902/bin"
GCC_BIN="$WORKSPACE/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"

chmod +x "$CLANG_BIN/clang"
test -x "$CLANG_BIN/clang"
test -x "$CLANG_BIN/ld.lld"
test -x "$GCC_BIN/aarch64-linux-androidkernel-gcc"

export PATH="$GCC_BIN:$CLANG_BIN:$PATH"

echo "=== CLANG ==="
"$CLANG_BIN/clang" --version
echo "=== LLD ==="
"$CLANG_BIN/ld.lld" --version
echo "=== GCC ==="
"$GCC_BIN/aarch64-linux-androidkernel-gcc" --version

# =============================================================================
# Step: Verify Source
# =============================================================================
step "Verify Source"

echo "=== KERNEL VERSION ==="
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile

echo "=== DEFCONFIG ==="
test -f "arch/arm64/configs/$DEFCONFIG"
echo "$DEFCONFIG"

echo "=== TOOLCHAIN CONFIG ==="
cat build.config.mtk.aarch64

# =============================================================================
# Step: Build Kernel
# =============================================================================
step "Build Kernel"

CLANG_DIR="$WORKSPACE/prebuilts/clang/host/linux-x86/clang-r383902"
GCC_BIN="$WORKSPACE/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"

export PATH="$CLANG_DIR/bin:$GCC_BIN:$PATH"
export LD_LIBRARY_PATH="$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"

CROSS_COMPILE="$GCC_BIN/aarch64-linux-androidkernel-"

# LOCALVERSION= prevents Git dirty-state '+' suffix.
# Keep it in every make invocation.
BUILD_ARGS=(
    -j"$(nproc)"
    O=out
    ARCH=arm64
    LOCALVERSION=
    CC=clang
    LD=ld.lld
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    AR=llvm-ar
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE="$CROSS_COMPILE"
)

echo "=== GENERATING CONFIG ==="
make "${BUILD_ARGS[@]}" "$DEFCONFIG"

echo "=== INSTALLING KERNEL HEADERS ==="
make O=out ARCH=arm64 headers_install

echo "=== BUILDING KERNEL ==="
timeout "${BUILD_TIMEOUT_MIN}m" \
    make "${BUILD_ARGS[@]}" Image.gz-dtb 2>&1 | tee build.log

echo "=== ACTUAL KERNEL RELEASE ==="
cat out/include/config/kernel.release

echo "=== BUILD OUTPUT ==="
find out/arch/arm64/boot -maxdepth 2 -type f

# =============================================================================
# Step: Upload Kernel Artifacts (local)
# =============================================================================
step "Upload Kernel Artifacts"

ARTIFACT_ROOT="$WORKSPACE/artifacts"
mkdir -p "$ARTIFACT_ROOT"

RUN_NUMBER_FILE="$ARTIFACT_ROOT/.run_number"
RUN_NUMBER=$(( $(cat "$RUN_NUMBER_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$RUN_NUMBER" > "$RUN_NUMBER_FILE"

ARTIFACT_NAME="Camellian-TOS-Kernel-${RUN_NUMBER}"
ARTIFACT_DIR="$ARTIFACT_ROOT/$ARTIFACT_NAME"
mkdir -p "$ARTIFACT_DIR"

ARTIFACT_FILES=(
    out/arch/arm64/boot/Image
    out/arch/arm64/boot/Image.gz
    out/arch/arm64/boot/Image.gz-dtb
    out/vmlinux
    out/System.map
    out/.config
    build.log
)

copied=0
for f in "${ARTIFACT_FILES[@]}"; do
    if [ -f "$f" ]; then
        cp --parents -a "$f" "$ARTIFACT_DIR/"
        copied=$((copied + 1))
    else
        warn "Not found, skipped: $f"
    fi
done

while IFS= read -r -d '' f; do
    cp --parents -a "$f" "$ARTIFACT_DIR/"
    copied=$((copied + 1))
done < <(find out/arch/arm64/boot -type f -name '*.dtb' -print0)

if [ "$copied" -eq 0 ]; then
    die "No artifact files were found."
fi

echo "=== ARTIFACT: $ARTIFACT_NAME ($copied files) ==="
( cd "$ARTIFACT_DIR" && find . -type f -printf '%10s %p\n' | sort -k2 )
echo
info "Done. Artifacts saved in: $ARTIFACT_DIR"
