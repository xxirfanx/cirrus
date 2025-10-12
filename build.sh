#!/usr/bin/env bash

# Constants
WORKDIR="$(pwd)"
RELEASE="v0.1"
KERNEL_NAME="XposedHook"
USER="admin"
HOST="XposedHook"
TIMEZONE="Asia/Hong_Kong"
ANYKERNEL_REPO="https://github.com/xxirfanx/anykernel"
ANYKERNEL_BRANCH="gki-2.0"
KERNEL_REPO="https://github.com/xxirfanx/android_kernel_common_android12-5.10"
KERNEL_BRANCH="mahiru-5-rose_r1"
KERNEL_DEFCONFIG="gki_defconfig"
GKI_RELEASES_REPO="https://github.com/xxirfanx/suki_su"
CLANG_URL="https://github.com/linastorvaldz/idk/releases/download/clang-r547379/clang.tgz"
CLANG_BRANCH=""
AK3_ZIP_NAME="android12-5.10.X-lts-AnyKernel3.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"

# Handle error
exec > >(tee $WORKDIR/build.log) 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

# Import functions
source $WORKDIR/functions.sh

# Set timezone
sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

# Clone kernel source
log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $KSRC

cd $KSRC
LINUX_VERSION=$(make kernelversion)
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
cd $WORKDIR

# Set Kernel variant
log "Setting Kernel variant..."
case "$KSU" in
  "Next") VARIANT="KSUN" ;;
  "Suki") VARIANT="SUKISU" ;;
  "None") VARIANT="NKSU" ;;
esac
susfs_included && VARIANT+="+SuSFS"

# Replace Placeholder in zip name
AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

# Download Clang
CLANG_DIR="$WORKDIR/clang"
CLANG_BIN="${CLANG_DIR}/bin"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "🔽 Downloading Clang..."
  wget -qO clang-archive "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  case "$(basename $CLANG_URL)" in
    *.tar.* | *.tgz)
      tar -xf clang-archive -C "$CLANG_DIR"
      ;;
    *.7z)
      7z x clang-archive -o${CLANG_DIR}/ -bd -y > /dev/null
      ;;
    *)
      error "Unsupported file format"
      ;;
  esac
  rm clang-archive

  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv $SINGLE_DIR/* $CLANG_DIR/
    rm -rf $SINGLE_DIR
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

# Clone GCC
log "Cloning GCC..."
GCC_DIR="$WORKDIR/gcc"
GCC_BIN="${GCC_DIR}/bin"
git clone --depth=1 -q \
  https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 \
  $GCC_DIR

# Clone Rust
log "Cloning Rust...."
RUST_DIR="$WORKDIR/rust"
RUST_BIN="${RUST_DIR}/linux-x86/1.73.0b/bin"
git clone --depth=1 -q \
  https://android.googlesource.com/platform/prebuilts/rust \
  -b main-kernel-build-2024 \
  $RUST_DIR

# Clone kernel build tools
log "Cloning Kbuild tools..."
KBUILD_TOOLS_DIR="$WORKDIR/kbuild-tools"
KBUILD_TOOLS_BIN="${KBUILD_TOOLS_DIR}/linux-x86/bin"
git clone --depth=1 -q \
  https://android.googlesource.com/kernel/prebuilts/build-tools \
  -b main-kernel-build-2024 \
  $KBUILD_TOOLS_DIR

export PATH="${CLANG_BIN}:${GCC_BIN}:${RUST_BIN}:${KBUILD_TOOLS_BIN}:$PATH"

# Extract clang version
COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

cd $KSRC

## KernelSU setup
if ksu_included; then
  # Remove existing KernelSU drivers
  for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU; do
    if [[ -d $KSU_PATH ]]; then
      log "KernelSU driver found in $KSU_PATH, Removing..."
      KSU_DIR=$(dirname "$KSU_PATH")

      [[ -f "$KSU_DIR/Kconfig" ]] && sed -i '/kernelsu/d' $KSU_DIR/Kconfig
      [[ -f "$KSU_DIR/Makefile" ]] && sed -i '/kernelsu/d' $KSU_DIR/Makefile

      rm -rf $KSU_PATH
    fi
  done

  # Install kernelsu
  case "$KSU" in
    "Next") install_ksu KernelSU-Next/KernelSU-Next next ;;
    "Suki") install_ksu SukiSU-Ultra/SukiSU-Ultra $(if susfs_included; then echo "susfs-main"; elif ksu_manual_hook; then echo "nongki"; else echo "main"; fi) ;;
  esac
  config --enable CONFIG_KSU
  config --disable CONFIG_KSU_MANUAL_SU
fi

# SUSFS
if susfs_included; then
  # Kernel-side
  log "Applying kernel-side susfs patches"
  SUSFS_DIR="$WORKDIR/susfs"
  SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"
  SUSFS_BRANCH=gki-android12-5.10
  git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu -b $SUSFS_BRANCH $SUSFS_DIR
  cp -R $SUSFS_PATCHES/fs/* ./fs
  cp -R $SUSFS_PATCHES/include/* ./include
  patch -p1 < $WORKDIR/kernel-patches//50_add_susfs_in_gki-android12-5.10.patch
  SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')

  # KernelSU-side
  if [[ "$KSU" == "Next" ]]; then
    log "Applying kernelsu-side susfs patches.."
    KERNEL_PATCHES_DIR="$PWD/kernel_patches"
    SUSFS_FIX_PATCHES="$KERNEL_PATCHES_DIR/next/susfs_fix_patches/$SUSFS_VERSION"
    git clone --depth=1 -q https://github.com/WildKernels/kernel_patches $KERNEL_PATCHES_DIR
    if [ ! -d "$SUSFS_FIX_PATCHES" ]; then
      error "susfs fix patches are not available for susfs $SUSFS_VERSION."
    fi
    cd KernelSU-Next
    patch -p1 < $SUSFS_PATCHES/KernelSU/10_enable_susfs_for_ksu.patch || true
    # apply the fix patches
    for p in "$SUSFS_FIX_PATCHES"/*.patch; do
      patch -p1 --forward --fuzz=3 < $p
    done
    # cleanup .orig / .rej
    find . -type f \( -name '*.orig' -o -name '*.rej' \) -delete
    cd $OLDPWD
  fi
  config --enable CONFIG_KSU_SUSFS
else
  config --disable CONFIG_KSU_SUSFS
fi

# KSU Manual Hooks
if ksu_manual_hook; then
  log "Applying manual hook patch"
  if [[ "$KSU" == "Suki" ]]; then
    patch -p1 --forward --fuzz=3 < $WORKDIR/kernel-patches/manual-hook-v1.5.patch
  else
    patch -p1 --forward < $WORKDIR/kernel-patches/manual-hook-v1.4.patch
  fi
  config --enable CONFIG_KSU_MANUAL_HOOK
  config --disable CONFIG_KSU_KPROBES_HOOK
  config --disable CONFIG_KSU_SUSFS_SUS_SU # Conflicts with manual hook
fi

# Enable KPM Supports for SukiSU
# if [[ $KSU == "Suki" ]]; then
#   config --enable CONFIG_KPM
# fi

# set localversion
if [[ $TODO == "kernel" ]]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  if [[ $STATUS == "BETA" ]]; then
    SUFFIX="$LATEST_COMMIT_HASH"
  else
    SUFFIX="${RELEASE}-${LATEST_COMMIT_HASH}"
  fi
  config --set-str CONFIG_LOCALVERSION "-$KERNEL_NAME-$SUFFIX"
fi

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(date)
MAKE_ARGS=(
  LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-android-
  -j$(nproc --all)
  O=$OUTDIR
  RUSTC=rustc
  PAHOLE=pahole
  LD=ld.lld HOSTLD=ld.lld
)
KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"

text=$(
  cat << EOF
🐧 *Linux Version*: $LINUX_VERSION
📅 *Build Date*: $KBUILD_BUILD_TIMESTAMP
📛 *KernelSU*: ${KSU}
ඞ *SuSFS*: $(susfs_included && echo "$SUSFS_VERSION" || echo "None")
🔰 *Compiler*: $COMPILER_STRING
EOF
)

## Build GKI
log "Generating config..."
make ${MAKE_ARGS[@]} $KERNEL_DEFCONFIG

# Upload defconfig if we are doing defconfig
if [[ $TODO == "defconfig" ]]; then
  log "Uploading defconfig..."
  upload_file $OUTDIR/.config
  exit 0
fi

# Build the actual kernel
log "Building kernel..."
make ${MAKE_ARGS[@]} Image

# Check KMI Function symbol
# $KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$MODULE_SYMVERS"

## Post-compiling stuff
cd $WORKDIR

# Patch the kernel Image for KPM Supports
#if [[ $KSU == "Suki" ]]; then
#  tempdir=$(mktemp -d) && cd $tempdir
#
#  # Setup patching tool
#  LATEST_SUKISU_PATCH=$(curl -s "https://api.github.com/repos/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest" | grep "browser_download_url" | grep "patch_linux" | cut -d '"' -f 4)
#  curl -Ls "$LATEST_SUKISU_PATCH" -o patch_linux
#  chmod a+x ./patch_linux
#
#  # Patch the kernel image
#  cp $KERNEL_IMAGE ./Image
#  sudo ./patch_linux
#  mv oImage Image
#  KERNEL_IMAGE=$(pwd)/Image
#
#  cd -
#fi

# Clone AnyKernel
log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

# Set kernel string in anykernel
if [[ $STATUS == "BETA" ]]; then
  BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d-%H%M")
  AK3_ZIP_NAME=${AK3_ZIP_NAME//BUILD_DATE/$BUILD_DATE}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-REL/}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${LINUX_VERSION} (${BUILD_DATE}) ${VARIANT}/g" \
    $WORKDIR/anykernel/anykernel.sh
else
  AK3_ZIP_NAME=${AK3_ZIP_NAME//-BUILD_DATE/}
  AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT}/g" \
    $WORKDIR/anykernel/anykernel.sh
fi

# Zip the anykernel
cd anykernel
log "Zipping anykernel..."
cp $KERNEL_IMAGE .
zip -r9 $WORKDIR/$AK3_ZIP_NAME ./*
cd $OLDPWD

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> $GITHUB_ENV
  mkdir -p $WORKDIR/artifacts
  mv $WORKDIR/*.zip $WORKDIR/artifacts
fi

if [[ $LAST_BUILD == "true" && $STATUS != "BETA" ]]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "SUSFS_VERSION=$(curl -s https://gitlab.com/simonpunk/susfs4ksu/raw/gki-android12-5.10/kernel_patches/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")"
  ) >> $WORKDIR/artifacts/info.txt
fi

if [[ $STATUS == "BETA" ]]; then
  upload_file "$WORKDIR/$AK3_ZIP_NAME" "$text"
  upload_file "$WORKDIR/build.log"
else
  send_msg "✅ Build Succeeded for $VARIANT variant."
fi

exit 0
