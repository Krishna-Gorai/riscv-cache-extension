#!/usr/bin/env bash
# =============================================================================
#  build.sh -- build every bare-metal kernel without needing make.
#
#  Windows hosts usually have the xPack toolchain but no make, so this mirrors
#  what the Makefile does. Override the toolchain location with TOOLCHAIN=...
#
#  Two flavours of kernel are built:
#
#    kernels/       single-PE kernels, linked with link.ld + crt0.S. They run
#                   entirely out of the local ITCM and are loaded there
#                   directly by tb_pe.
#
#    soc_kernels/   multi-PE kernels, linked with link_soc.ld + crt0_soc.S.
#                   The whole image is loaded into the shared instruction
#                   memory, and each PE copies its ITCM image out of it at
#                   boot, as Section IV-A of the paper describes.
#
#  Usage:  ./build.sh                 build everything
#          ./build.sh smoke           build one single-PE kernel
#          ./build.sh soc:par_smoke   build one SoC kernel
# =============================================================================
set -euo pipefail

# Probe the usual install locations.
if [ -z "${TOOLCHAIN:-}" ]; then
  for cand in /c/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin \
              /d/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin; do
    if [ -x "$cand/riscv-none-elf-gcc.exe" ] || [ -x "$cand/riscv-none-elf-gcc" ]; then
      TOOLCHAIN="$cand"
      break
    fi
  done
fi
TOOLCHAIN="${TOOLCHAIN:?no RISC-V toolchain found; set TOOLCHAIN=/path/to/bin}"
PREFIX="${RISCV_PREFIX:-riscv-none-elf-}"

CC="$TOOLCHAIN/${PREFIX}gcc"
OBJCOPY="$TOOLCHAIN/${PREFIX}objcopy"
OBJDUMP="$TOOLCHAIN/${PREFIX}objdump"

ARCH=rv32imc_zicsr
ABI=ilp32

# Extra -D flags and an output-name suffix, so one source can be built at each
# of the sizes the paper evaluates without editing it:
#   KCFLAGS="-DBENCH_N=64 -DBENCH_GOLDEN=0x1CDFA3A6u" OUT_SUFFIX=_64 \
#     ./build.sh soc:bench_matmul
KCFLAGS="${KCFLAGS:-}"
OUT_SUFFIX="${OUT_SUFFIX:-}"

cd "$(dirname "$0")"
mkdir -p build

build_one() {
  kind="$1"; name="$2"
  if [ "$kind" = "soc" ]; then
    src="soc_kernels/$name.c"
    ld="lib/link_soc.ld"
    crt="lib/crt0_soc.S"
    out="build/soc_$name$OUT_SUFFIX"
    # The SoC image lives in the shared instruction memory, so the boot stub
    # section is part of the binary alongside the ITCM load image.
    sections="--only-section=.boot --only-section=.text --only-section=.rodata --only-section=.data"
  else
    src="kernels/$name.c"
    ld="lib/link.ld"
    crt="lib/crt0.S"
    out="build/$name$OUT_SUFFIX"
    sections="--only-section=.text --only-section=.rodata --only-section=.data"
  fi

  echo "== $kind:$name$OUT_SUFFIX ${KCFLAGS:+[$KCFLAGS]} =="
  "$CC" -march=$ARCH -mabi=$ABI -mcmodel=medlow \
        -Os -g -std=c11 -ffreestanding -fno-builtin -fno-common \
        $KCFLAGS \
        -Wall -Wextra -Ilib \
        -nostdlib -nostartfiles -T "$ld" -Wl,--gc-sections \
        -Wl,-Map,"$out.map" \
        -o "$out.elf" "$crt" "$src" 2>&1 \
    | grep -v "LOAD segment with RWX permissions" || true

  "$OBJCOPY" -O binary $sections "$out.elf" "$out.bin"
  python ../scripts/bin2hex.py "$out.bin" "$out.hex"
  "$OBJDUMP" -d -S "$out.elf" > "$out.dis"
}

if [ $# -gt 0 ]; then
  for arg in "$@"; do
    case "$arg" in
      soc:*) build_one soc "${arg#soc:}" ;;
      *)     build_one pe  "$arg" ;;
    esac
  done
else
  for f in kernels/*.c;     do [ -e "$f" ] && build_one pe  "$(basename "$f" .c)"; done
  for f in soc_kernels/*.c; do [ -e "$f" ] && build_one soc "$(basename "$f" .c)"; done
fi

echo "done -> sw/build/"
