#!/usr/bin/env bash
#
# Optimized Kernel Build Script
# Enhanced with better error handling, performance optimizations, and modular structure
#

# Use -e for exit on error, -o pipefail for error in pipe
set -eo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# Global variables
declare -g KERNEL_NAME="XposedHook"
declare -g START_TIME
declare -g BUILD_STATUS="failed"

## Main Function Declarations
#---------------------------------------------------------------------------------

validate_environment() {
    log_info "Validating environment variables..."
    
    local required_vars=(
        "CIRRUS_WORKING_DIR" "DEVICE_CODENAME" "TG_TOKEN" 
        "TG_CHAT_ID" "BUILD_USER" "BUILD_HOST" "ANYKERNEL"
        "KERNEL_SOURCE" "KERNEL_BRANCH" "CLANG_ROOTDIR"
    )
    
    if [[ "$KPM_PATCH" == "true" ]]; then
        required_vars+=("KPM_VERSION")
    fi
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
}

setup_env() {
    log_info "Setting up build environment..."
    
    # Core directories (CLANG_ROOTDIR is set in .cirrus.yml and download.sh)
    export KERNEL_ROOTDIR="$CIRRUS_WORKING_DIR/$DEVICE_CODENAME"
    export KERNEL_OUTDIR="$KERNEL_ROOTDIR/out"
    export ANYKERNEL_DIR="$CIRRUS_WORKING_DIR/AnyKernel"
    export CCACHE_DIR="${CCACHE_DIR:-/tmp/ccache}"
    export LD="$bin_dir/ld.lld"

    # Create necessary directories
    mkdir -p "$KERNEL_OUTDIR" "$ANYKERNEL_DIR" "$CCACHE_DIR"

    # PATH setup
    export PATH="$CLANG_ROOTDIR/bin:$PATH:/usr/lib/ccache"
    export LD_LIBRARY_PATH="$CLANG_ROOTDIR/lib:$LD_LIBRARY_PATH"

    # Toolchain validation (re-check)
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
    export IMAGE="$KERNEL_OUTDIR/arch/arm64/boot/$TYPE_IMAGE"
    export DTBO="$KERNEL_OUTDIR/arch/arm64/boot/dtbo.img"
    export DATE=$(date +"%Y%m%d-%H%M%S")
    export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
    export BOT_DOC_URL="https://api.telegram.org/bot$TG_TOKEN/sendDocument"
    export START_TIME=$(date +%s)
    
    # Use NUM_CORES from system (nproc)
    export NUM_CORES=$(nproc)
    if [[ "$BUILD_OPTIONS" != "-j"* ]]; then
        export BUILD_OPTIONS="-j$NUM_CORES" # Fallback if not set in .cirrus.yml
    fi
    
    # CCache configuration
    if [[ "$CCACHE" == "true" ]]; then
        export CCACHE_DIR
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
        log_info "CCache enabled: $CCACHE_DIR (max: $CCACHE_MAXSIZE)"
    fi
}

tg_post_msg() {
    local message="$1"
    local parse_mode="${2:-html}"
    
    if curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=$parse_mode" \
        -d text="$message" > /dev/null; then
        log_debug "Telegram message sent successfully"
    else
        log_warning "Failed to send Telegram message"
    fi
}

tg_send_sticker() {
    local sticker_id="$1"
    # Note: Using the base bot URL + sendSticker endpoint
    local BOT_STICKER_URL="https://api.telegram.org/bot$TG_TOKEN/sendSticker"
    curl -s -X POST "$BOT_STICKER_URL" \
        -d sticker="$sticker_id" \
        -d chat_id="$TG_CHAT_ID" > /dev/null
}

cleanup() {
    local exit_code=$?
    local end_time=$(date +%s)
    local build_time=$((end_time - START_TIME))
    
    if [[ $exit_code -eq 0 && "$BUILD_STATUS" == "success" ]]; then
        log_success "Build completed successfully in ${build_time}s"
        tg_send_sticker "CAACAgQAAx0EabRMmQACAm9jET5WwKp2FMYITmo6O8CJxt3H2wACFQwAAtUjEFPkKwhxHG8_Kx4E"
    else
        log_error "Build failed with exit code $exit_code"
        send_failure_log
        tg_send_sticker "CAACAgQAAx0EabRMmQACAnRjEUAXBTK1Ei_zbJNPFH7WCLzSdAACpBEAAqbxcR716gIrH45xdB4E"
    fi
    
    # Removal of temporary files is now handled more robustly in done.sh, 
    # but keep the necessary cleanup here if done.sh doesn't run.
    rm -rf "$CIRRUS_WORKING_DIR"/*.tar.* 2>/dev/null || true
    
    # Exit with the original exit code
    exit $exit_code
}

send_failure_log() {
    local log_file="$CIRRUS_WORKING_DIR/build_error.log"
    
    log_error "Build failed. Collecting error information..."
    
    # Ensure no previous log remains
    rm -f "$log_file"

    # Capture dmesg (system logs) which often contain kernel build errors
    dmesg | tail -50 > "$log_file" 2>/dev/null || echo "Unable to capture system logs" > "$log_file"
    echo -e "\n=== Build Environment ===" >> "$log_file"
    env | grep -E "(CIRRUS|KERNEL|TG_|BUILD_|CLANG_)" >> "$log_file"
    
    if [[ -f "$log_file" ]]; then
        log_info "Sending failure log to Telegram..."
        
        # Use basename for the document name in Telegram
        local doc_name="$(basename "$log_file")"

        if curl -F document=@"$log_file" -F filename="$doc_name" "$BOT_DOC_URL" \
            -F chat_id="$TG_CHAT_ID" \
            -F "disable_web_page_preview=true" \
            -F "parse_mode=html" \
            -F caption="❌ <b>Kernel Build Failed</b>%0ADevice: <code>$DEVICE_CODENAME</code>%0ATime: $(date +'%Y-%m-%d %H:%M:%S')" > /dev/null; then
            log_success "Failure log sent."
        else
            log_warning "Failed to send error log"
        fi
    fi
}

display_banner() {
    echo -e "${CYAN}"
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
    log_info "DEVICE_CODENAME      = ${DEVICE_CODENAME}"
    log_info "DEVICE_DEFCONFIG     = ${DEVICE_DEFCONFIG}"
    log_info "TOOLCHAIN_VERSION    = ${KBUILD_COMPILER_STRING}"
    log_info "CLANG_ROOTDIR        = ${CLANG_ROOTDIR}"
    log_info "KERNEL_ROOTDIR       = ${KERNEL_ROOTDIR}"
    log_info "KERNEL_OUTDIR        = ${KERNEL_OUTDIR}"
    log_info "BUILD OPTIONS        = ${BUILD_OPTIONS}"
    log_info "AVAILABLE CORES      = ${NUM_CORES}"
    echo "================================================"
}

install_kernelsu() {
    if [ "$KERNELSU" = "true" ]; then
        local url=""
        case "$KERNELSU_TYPE" in
            "sukisu")
                log_info "Installing SUKISU ULTRA..."
                url="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/refs/heads/main/kernel/setup.sh"
                ;;
            "rksu")
                log_info "Installing RKSU..."
                url="https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh"
                ;;
            "kernelsunext")
                log_info "Installing KERNELSU NEXT..."
                url="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/next/kernel/setup.sh"
                ;;
            *)
                log_warning "Invalid KERNELSU_TYPE: '$KERNELSU_TYPE'. Continuing build without KernelSU."
                return 1
                ;;
        esac

        if [[ -n "$url" ]]; then
            log_info "Executing $KERNELSU_TYPE setup script from $url"
            curl -LSs "$url" | bash -s "$KERNELSU_BRANCH" || {
                log_warning "$KERNELSU_TYPE installation failed, check logs. Continuing build..."
            }
        fi
    fi
}

compile_kernel() {
    cd "$KERNEL_ROOTDIR"
    
    # Ensure a clean build state before starting
    log_info "Cleaning working directory (git clean -fdx)..."
    git clean -fdx 
    
    tg_post_msg "🚀 <b>Kernel Build Started</b>%0A📱 <b>Device:</b> <code>$DEVICE_CODENAME</code>%0A⚙️ <b>Defconfig:</b> <code>$DEVICE_DEFCONFIG</code>%0A🔧 <b>Toolchain:</b> <code>$KBUILD_COMPILER_STRING</code>"
    
    # Optimized build flags
    export LLVM=1
    export LLVM_IAS=1

    # Use CCache if enabled
    if [[ "$CCACHE" == "true" ]]; then                                  export CC="ccache clang" # Use ccache wrapper
        log_info "CCache statistics before build:"
        ccache -s                                                   else
        export CC="clang"                                           fi

    log_info "Step 1/4: Configuring defconfig..."
    # Clean output directory config before creating new one
    rm -f "$KERNEL_OUTDIR/.config"
    make O="$KERNEL_OUTDIR" ARCH=arm64 CC="$CC" CROSS_COMPILE="aarch64-linux-gnu-" CLANG_TRIPLE="aarch64-linux-gnu-" "$DEVICE_DEFCONFIG" || {
        log_error "Defconfig configuration failed"
        return 1
    }
    
    log_info "Step 2/4: Installing KernelSU..."
    install_kernelsu
    
    log_info "Step 3/4: Starting kernel compilation... ($BUILD_OPTIONS)"
    
    local build_targets=("$TYPE_IMAGE")
    [[ "$BUILD_DTBO" == "true" ]] && build_targets+=("dtbo.img")
    
    # Execute the single, correct build command
       if make $BUILD_OPTIONS \
        ARCH=arm64 \
        O="$KERNEL_OUTDIR" \
        CC="$CC" \
        CROSS_COMPILE="aarch64-linux-gnu-" \
        CROSS_COMPILE_ARM32="arm-linux-gnueabi-" \
        CLANG_TRIPLE="aarch64-linux-gnu-" \
	"${build_targets[@]}"; then
        
        log_success "Kernel compilation completed"
    else
        log_error "Kernel compilation failed"
        return 1
    fi
    
    # Verify output
    if [[ ! -f "$IMAGE" ]]; then
        log_error "Kernel Image not found at expected location: $IMAGE"
        return 1
    fi
    
    log_info "Step 4/4: Build verification completed"
    
    # Show CCache statistics if enabled
    if [[ "$CCACHE" == "true" ]]; then
        log_info "CCache statistics after build:"
        ccache -s
    fi
}

patch_kpm() {
    if [[ "$KPM_PATCH" == "true" ]] && [[ "$KERNELSU" == "true" ]]; then
        log_info "KPM patch is enabled (Version: $KPM_VERSION)"
        cd "$KERNEL_OUTDIR/arch/arm64/boot"
        
        local download_url="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/$KPM_VERSION/patch_linux"
        log_info "Downloading KPM patcher from $download_url"

        if ! wget -q "$download_url"; then
             log_error "Failed to download KPM patcher version $KPM_VERSION. Aborting patch."
             return 1
        fi

        chmod +x patch_linux
        log_info "Applying KPM patch to $TYPE_IMAGE..."
        
        # Execute patcher
        ./patch_linux "$TYPE_IMAGE" || { # Pass the Image name explicitly to be safe
            log_error "KPM patch execution failed! Check if it supports $TYPE_IMAGE"
            return 1
        }

        # File verification and replacement
        if [[ -f "oImage" ]]; then
            rm -f "$TYPE_IMAGE"
            mv oImage "$TYPE_IMAGE"
            log_success "KPM patch applied successfully. New image is $TYPE_IMAGE."
        else
            log_error "KPM patcher did not produce 'oImage'. Patch failed!"
            return 1 
        fi
    else
        log_info "KPM patch is disabled or KERNELSU is false."
    fi
}

prepare_anykernel() {
    log_info "Preparing AnyKernel..."
    
    # Clean AnyKernel directory first (already done by git clone below, but good practice)
    [[ -d "$ANYKERNEL_DIR" ]] && rm -rf "$ANYKERNEL_DIR"
    
    if git clone --depth=1 --single-branch "$ANYKERNEL" "$ANYKERNEL_DIR"; then
        cd "$ANYKERNEL_DIR"
        
        # Copy kernel image(s)
        if [ "$BUILD_DTBO" = "true" ]; then
            if cp -f "$IMAGE" "$DTBO" .; then
                log_success "AnyKernel preparation completed: Image and dtbo.img copied."
            else
                log_error "Failed to copy kernel image and dtbo.img to AnyKernel"
                return 1
            fi
        else
            if cp -f "$IMAGE" .; then # Copy to current directory (AnyKernel root)
                log_success "AnyKernel preparation completed: Image copied."
            else
                log_error "Failed to copy kernel Image to AnyKernel"
                return 1
            fi
        fi
    else
        log_error "Failed to clone AnyKernel repository"
        return 1
    fi
}

get_build_info() {
    cd "$KERNEL_ROOTDIR"
    
    # Kernel version info
    local config_file="$KERNEL_OUTDIR/.config"
    if [[ -f "$config_file" ]]; then
        export KERNEL_VERSION=$(grep 'Linux/arm64' "$KERNEL_OUTDIR/.config" | cut -d' ' -f3 || echo "N/A")
    fi
    
    local compile_h="$KERNEL_OUTDIR/include/generated/compile.h"
    if [[ -f "$compile_h" ]]; then
        export UTS_VERSION=$(grep 'UTS_VERSION' "$compile_h" | cut -d'"' -f2 || echo "N/A")
    fi
    
    # Git information
    export LATEST_COMMIT=$(git log --pretty=format:'%s' -1 2>/dev/null | head -c 100 | tr -d '\n' || echo "N/A")
    export COMMIT_BY=$(git log --pretty=format:'by %an' -1 2>/dev/null | tr -d '\n' || echo "N/A")
    export BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
    
    # Get the repo owner/name from the URL, defaulting to CIRRUS vars
    local repo_url="${KERNEL_SOURCE:-https://github.com/unknown/unknown}"
    local owner_repo=$(echo "$repo_url" | sed -E 's/https:\/\/github.com\/([^\/]+\/[^\/]+).*/\1/i')
    export KERNEL_SOURCE="$owner_repo"
    
    export KERNEL_BRANCH="$BRANCH"
    export COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
}

create_and_push_zip() {
    cd "$ANYKERNEL_DIR"
    
    local zip_name="$KERNEL_NAME-$DEVICE_CODENAME-$DATE.zip"
    
    log_info "Creating flashable ZIP: $zip_name"
    
    if zip -r9 "$zip_name" * > /dev/null; then # Silence zip output
        log_success "ZIP creation completed"
    else
        log_error "ZIP creation failed"
        return 1
    fi
    
    # Calculate checksums
    local zip_sha1=$(sha1sum "$zip_name" | cut -d' ' -f1)
    local zip_md5=$(md5sum "$zip_name" | cut -d' ' -f1)
    local zip_sha256=$(sha256sum "$zip_name" | cut -d' ' -f1)
    local zip_size=$(du -h "$zip_name" | cut -f1)
    
    # Calculate build time
    local end_time=$(date +%s)
    local build_time=$((end_time - START_TIME))
    local minutes=$((build_time / 60))
    local seconds=$((build_time % 60))
    
    log_info "Uploading build to Telegram..."
    
    local caption="
✅ <b>Build Finished Successfully!</b>

📦 <b>Kernel:</b> <code>$KERNEL_NAME</code>
📱 <b>Device:</b> <code>$DEVICE_CODENAME</code>
👤 <b>Builder:</b> <code>$BUILD_USER@$BUILD_HOST</code>

🔧 <b>Build Info:</b>
├ Linux version: <code>${KERNEL_VERSION:-N/A}</code>
├ Branch: <code>${BRANCH:-N/A}</code>
├ Commit: <code>${LATEST_COMMIT:-N/A}</code>
├ Author: <code>${COMMIT_BY:-N/A}</code>
├ Uts: <code>${UTS_VERSION:-N/A}</code>
└ Compiler: <code>${KBUILD_COMPILER_STRING:-N/A}</code>

📊 <b>File Info:</b>
├ Size: $zip_size
├ SHA256: <code>${zip_sha256:0:16}...</code>
├ MD5: <code>$zip_md5</code>
└ SHA1: <code>${zip_sha1:0:16}...</code>

⏱️ <b>Build Time:</b> ${minutes}m ${seconds}s
📝 <b>Changes:</b> <a href=\"https://github.com/$KERNEL_SOURCE/commits/$KERNEL_BRANCH\">View on GitHub</a>"
    
    # Use basename for the document name in Telegram
    local doc_name="$(basename "$zip_name")"

    if curl -F document=@"$zip_name" -F filename="$doc_name" "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$caption" > /dev/null; then
        log_success "Build uploaded successfully!"
        log_info "File: $zip_name"
        log_info "Size: $zip_size"
        log_info "Build time: ${minutes}m ${seconds}s"
        
        # Set build status for cleanup
        BUILD_STATUS="success"
    else
        log_error "Failed to upload build to Telegram"
        return 1
    fi
}

## Main Execution Flow
#---------------------------------------------------------------------------------

main() {
    log_info "Starting optimized kernel build process..."
    START_TIME=$(date +%s)
    
    # Setup and validation
    validate_environment
    setup_env
    display_banner
    
    # Build process
    compile_kernel || return 1
    patch_kpm
    prepare_anykernel || return 1
    get_build_info
    create_and_push_zip || return 1
    
    log_success "All tasks completed successfully!"
    return 0
}

# Trap signals (always run cleanup on script exit)
trap cleanup EXIT INT TERM

# Run main function
main "$@"
