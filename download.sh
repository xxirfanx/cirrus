#!/usr/bin/env bash

echo "Downloading Kernel Sources.."
git clone --depth 1 --recurse-submodules $KERNEL_SOURCE -b $KERNEL_BRANCH $CIRRUS_WORKING_DIR/$DEVICE_CODENAME
echo ""
echo "Downloading Toolchain.."
bash <(wget -qO- https://raw.githubusercontent.com/greenforce-project/greenforce_clang/refs/heads/main/get_clang.sh)
