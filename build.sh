#!/usr/bin/env bash
#
# Optimized Kernel Build Script
# Enhanced with better error handling and performance optimizations
#

set -eo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

## Main Function Declarations
#---------------------------------------------------------------------------------

setup_env() {
    log_info "Setting up environment variables..."
    
    # Validate required environment variables
    local required_vars=(
        "CIRRUS_WORKING_DIR" "DEVICE_CODENAME" "TG_TOKEN" 
        "TG_CHAT_ID" "BUILD_USER" "BUILD_HOST" "ANYKERNEL"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            log_error "Required variable $var is not set"
            exit 1
        fi
    done

    # Core directories
    export KERNEL_NAME="mrt-Kernel"
    export KERNEL_ROOTDIR="$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    export DEVICE_DEFCONFIG="vendor/bengal-perf_defconfig"
    export CLANG_ROOTDIR="$CIRRUS_WORKING_DIR/greenforce-clang"
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"
    export ANYKERNEL_DIR="$CIRRUS_WORKING_DIR/AnyKernel"

    # Toolchain validation
    if [[ ! -d "$CLANG_ROOTDIR" || ! -f "$CLANG_ROOTDIR/bin/clang" ]]; then
        log_error "Toolchain (Clang) not found at $CLANG_ROOTDIR"
        exit 1
    fi

    # Toolchain versions
    local bin_dir="$CLANG_ROOTDIR/bin"
    export CLANG_VER="$("$bin_dir/clang" --version | head -n1 | sed -E 's/\(http[^)]+\)//g' | awk '{$1=$1};1')"
    export LLD_VER="$("$bin_dir/ld.lld" --version | head -n1)"
    
    # KBUILD variables
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST" 
    export KBUILD_COMPILER_STRING="$CLANG_VER with $LLD_VER"

    # Build variables
    export IMAGE="$KERNEL_OUTDIR/arch/arm64/boot/Image"
    export DATE=$(date +"%Y%m%d-%H%M%S")
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"
    export START_TIME=$(date +%s)
    
    # Create necessary directories
    mkdir -p "$KERNEL_OUTDIR" "$ANYKERNEL_DIR"
}

tg_post_msg() {
    local message="$1"
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="$message" > /dev/null
}

finerr() {
    local log_file="build.log"
    local log_url="https://api.cirrus-ci.com/v1/task/$CIRRUS_TASK_ID/logs/Build_kernel.log"
    
    log_error "Build failed. Retrieving logs..."
    
    if wget -q "$log_url" -O "$log_file"; then
        log_info "Sending failure log to Telegram..."
        
        curl -F document=@"$log_file" "$BOT_DOC_URL" \
            -F chat_id="$TG_CHAT_ID" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="==============================%0A<b>    Building Kernel CLANG Failed [❌]</b>%0A<b>        Jiancong Tenan 🤬</b>%0A=============================="
        
        # Send sticker
        curl -s -X POST "$BOT_MSG_URL/../sendSticker" \
            -d sticker="CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E" \
            -d chat_id="$TG_CHAT_ID" > /dev/null
    else
        log_error "Failed to retrieve logs from Cirrus CI"
        tg_post_msg "<b>Kernel Build Failed [❌]</b>%0A(Failed to get logs)."
    fi
    
    exit 1
}

display_banner() {
    echo -e "${BLUE}"
    cat << "BANNER"
================================================
              _  __  ____  ____               
             / |/ / / __/ / __/               
      __    /    / / _/  _\ \    __           
     /_/   /_/|_/ /_/   /___/   /_/           
    ___  ___  ____     _________________      
   / _ \/ _ \/ __ \__ / / __/ ___/_  __/      
  / ___/ , _/ /_/ / // / _// /__  / /         
 /_/  /_/|_|\____/\___/___/\___/ /_/          
================================================
BANNER
    echo -e "${NC}"
    
    log_info "BUILDER NAME         = ${KBUILD_BUILD_USER}"
    log_info "BUILDER HOSTNAME     = ${KBUILD_BUILD_HOST}"
    log_info "DEVICE_DEFCONFIG     = ${DEVICE_DEFCONFIG}"
    log_info "TOOLCHAIN_VERSION    = ${KBUILD_COMPILER_STRING}"
    log_info "CLANG_ROOTDIR        = ${CLANG_ROOTDIR}"
    log_info "KERNEL_ROOTDIR       = ${KERNEL_ROOTDIR}"
    log_info "KERNEL_OUTDIR        = ${KERNEL_OUTDIR}"
    echo "================================================"
}

compile_kernel() {
    cd "$KERNEL_ROOTDIR"
    
    local bin_dir="$CLANG_ROOTDIR/bin"
    local num_cores=$(nproc)
    
    tg_post_msg "<b>Build Kernel started..</b>%0A<b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>%0A<b>Toolchain:</b> <code>$KBUILD_COMPILER_STRING</code>"
    
    log_info "Configuring defconfig..."
    make -j"$num_cores" O="$KERNEL_OUTDIR" ARCH=arm64 "$DEVICE_DEFCONFIG" || finerr
    
    log_info "Installing KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main || {
        log_warning "KernelSU installation failed, continuing build..."
    }
    
    log_info "Starting kernel compilation..."
    
    # Optimized build flags
    export LLVM=1
    export LLVM_IAS=1
    
    make -j"$num_cores" ARCH=arm64 O="$KERNEL_OUTDIR" \
        CC="$bin_dir/clang" \
        AR="$bin_dir/llvm-ar" \
        AS="$bin_dir/llvm-as" \
        LD="$bin_dir/ld.lld" \
        NM="$bin_dir/llvm-nm" \
        OBJCOPY="$bin_dir/llvm-objcopy" \
        OBJDUMP="$bin_dir/llvm-objdump" \
        OBJSIZE="$bin_dir/llvm-size" \
        READELF="$bin_dir/llvm-readelf" \
        STRIP="$bin_dir/llvm-strip" \
        HOSTCC="$bin_dir/clang" \
        HOSTCXX="$bin_dir/clang++" \
        HOSTLD="$bin_dir/ld.lld" \
        CROSS_COMPILE="$bin_dir/aarch64-linux-gnu-" \
        CROSS_COMPILE_ARM32="$bin_dir/arm-linux-gnueabi-" || finerr
    
    # Verify output image
    if [[ ! -f "$IMAGE" ]]; then
        log_error "Image not found after compilation"
        finerr
    fi
    
    log_success "Kernel compilation completed"
}

prepare_anykernel() {
    log_info "Preparing AnyKernel..."
    
    rm -rf "$ANYKERNEL_DIR"
    git clone --depth=1 --single-branch "$ANYKERNEL" "$ANYKERNEL_DIR" || finerr
    
    # Copy kernel image
    cp -f "$IMAGE" "$ANYKERNEL_DIR" || finerr
    log_success "AnyKernel preparation completed"
}

get_build_info() {
    cd "$KERNEL_ROOTDIR"
    
    # Kernel version info
    if [[ -f "$KERNEL_OUTDIR/.config" ]]; then
        export KERNEL_VERSION=$(grep 'Linux/arm64' "$KERNEL_OUTDIR/.config" | cut -d' ' -f3 || echo "N/A")
    fi
    
    if [[ -f "$KERNEL_OUTDIR/include/generated/compile.h" ]]; then
        export UTS_VERSION=$(grep 'UTS_VERSION' "$KERNEL_OUTDIR/include/generated/compile.h" | cut -d'"' -f2 || echo "N/A")
    fi
    
    # Git information
    export LATEST_COMMIT=$(git log --pretty=format:'%s' -1 2>/dev/null || echo "N/A")
    export COMMIT_BY=$(git log --pretty=format:'by %an' -1 2>/dev/null || echo "N/A")
    export BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
    export KERNEL_SOURCE="${CIRRUS_REPO_OWNER:-unknown}/${CIRRUS_REPO_NAME:-unknown}"
    export KERNEL_BRANCH="$BRANCH"
}

create_and_push_zip() {
    cd "$ANYKERNEL_DIR"
    
    local zip_name="$KERNEL_NAME-$DEVICE_CODENAME-$DATE.zip"
    
    log_info "Creating flashable ZIP..."
    zip -r9 "$zip_name" . || finerr
    
    # Calculate checksums
    local zip_sha1=$(sha1sum "$zip_name" | cut -d' ' -f1)
    local zip_md5=$(md5sum "$zip_name" | cut -d' ' -f1)
    
    # Calculate build time
    local end_time=$(date +%s)
    local build_time=$((end_time - START_TIME))
    local minutes=$((build_time / 60))
    local seconds=$((build_time % 60))
    
    log_info "Sending build to Telegram..."
    
    local caption="
==========================
<b>✅ Build Finished!</b>
<b>📦 Kernel:</b> $KERNEL_NAME
<b>📱 Device:</b> $DEVICE_CODENAME
<b>👤 Owner:</b> ${CIRRUS_REPO_OWNER:-unknown}
<b>🏚️ Linux version:</b> ${KERNEL_VERSION:-N/A}
<b>🌿 Branch:</b> ${BRANCH:-N/A}
<b>🎁 Top commit:</b> ${LATEST_COMMIT:-N/A}
<b>📚 SHA1:</b> <code>$zip_sha1</code>
<b>📚 MD5:</b> <code>$zip_md5</code>
<b>👩‍💻 Commit author:</b> ${COMMIT_BY:-N/A}
<b>🐧 UTS version:</b> ${UTS_VERSION:-N/A}
<b>💡 Compiler:</b> $KBUILD_COMPILER_STRING
==========================
<b>⏱️ Compile took:</b> ${minutes}m ${seconds}s
<b>⚙️ Changes:</b> <a href=\"https://github.com/$KERNEL_SOURCE/commits/$KERNEL_BRANCH\">Here</a>"

    curl -F document=@"$zip_name" "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$caption" > /dev/null
    
    log_success "Build completed and uploaded successfully!"
    log_info "File: $zip_name"
    log_info "Build time: ${minutes}m ${seconds}s"
}

## Main Execution Flow
#---------------------------------------------------------------------------------

main() {
    log_info "Starting kernel build process..."
    
    # Setup and validation
    setup_env
    display_banner
    
    # Build process
    compile_kernel
    prepare_anykernel
    get_build_info
    create_and_push_zip
    
    log_success "All tasks completed successfully!"
}

# Trap errors and interrupts
trap finerr ERR
trap 'log_error "Build interrupted"; exit 1' INT TERM

# Run main function
main "$@"
