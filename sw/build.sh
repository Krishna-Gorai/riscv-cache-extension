#!/usr/bin/env bash
# =============================================================================
#  build.sh -- build every bare-metal kernel without needing make.
#
#  Windows hosts usually have the xPack toolchain but no make, so this mirrors
#  what the Makefile does. Override the toolchain location with TOOLCHAIN=...
#
#  Usage:  ./build.sh            build all kernels
#          ./build.sh smoke      build one kernel
# =============================================================================
set -euo pipefail

TOOLCHAIN="${TOOLCHAIN:-/d/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin}"
PREFIX="${RISCV_PREFIX:-riscv-none-elf-}"

CC="$TOOLCHAIN/${PREFIX}gcc"
OBJCOPY="$TOOLCHAIN/${PREFIX}objcopy"
OBJDUMP="$TOOLCHAIN/${PREFIX}objdump"

ARCH=rv32imc_zicsr
ABI=ilp32

cd "$(dirname "$0")"
mkdir -p build

if [ $# -gt 0 ]; then
  kernels=("$@")
else
  kernels=()
  for f in kernels/*.c; do
    kernels+=("$(basename "$f" .c)")
  done
fi

for k in "${kernels[@]}"; do
  echo "== $k =="
  "$CC" -march=$ARCH -mabi=$ABI -mcmodel=medlow \
        -Os -g -std=c11 -ffreestanding -fno-builtin -fno-common \
        -Wall -Wextra -Ilib \
        -nostdlib -nostartfiles -T lib/link.ld -Wl,--gc-sections \
        -Wl,-Map,"build/$k.map" \
        -o "build/$k.elf" lib/crt0.S "kernels/$k.c" 2>&1 \
    | grep -v "LOAD segment with RWX permissions" || true

  "$OBJCOPY" -O binary \
        --only-section=.text --only-section=.rodata --only-section=.data \
        "build/$k.elf" "build/$k.bin"

  python ../scripts/bin2hex.py "build/$k.bin" "build/$k.hex"
  "$OBJDUMP" -d -S "build/$k.elf" > "build/$k.dis"
done

echo "done -> sw/build/"
