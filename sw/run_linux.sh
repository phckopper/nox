#!/bin/bash
# Boot Linux on NoX Verilator simulator
#
# Memory map:
#   0x80000000  OpenSBI fw_jump.elf  (loaded as ELF, runs at reset)
#   0x80200000  Linux kernel Image   (raw binary blob)
#   0x87e00000  Device tree blob     (raw binary blob)
#
# Usage: ./sw/run_linux.sh [-s <cycles>] [-w <wave_start_cycle>]

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

# Clone and build OpenSBI if not already built:
#   cd sw && git clone --depth=1 https://github.com/riscv-software-src/opensbi.git
#   cp -r sw/opensbi-nox-platform sw/opensbi/platform/nox
#   cd sw/opensbi && make CROSS_COMPILE=riscv64-linux-gnu- PLATFORM=nox -j$(nproc)
OPENSBI_ELF="$SCRIPT_DIR/opensbi/build/platform/nox/firmware/fw_jump.elf"
KERNEL_IMG="$SCRIPT_DIR/linux/arch/riscv/boot/Image"
DTB="$SCRIPT_DIR/nox.dtb"
SIMULATOR="$ROOT/output_linux_sim/nox_sim_linux"

SIM_CYCLES=500000000   # 500M cycles (~5s wall at ~100 MHz sim rate)
WAVE_START=0

while [[ "$#" -gt 0 ]]; do
  case $1 in
    -s) SIM_CYCLES="$2"; shift;;
    -w) WAVE_START="$2"; shift;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
  shift
done

echo "========================================"
echo "  NoX Linux Boot"
echo "  OpenSBI : $OPENSBI_ELF"
echo "  Kernel  : $KERNEL_IMG"
echo "  DTB     : $DTB"
echo "  Cycles  : $SIM_CYCLES"
echo "========================================"

for f in "$OPENSBI_ELF" "$KERNEL_IMG" "$DTB" "$SIMULATOR"; do
  [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done

# Copy sim binary to /tmp so it can run without root
TMP_SIM=/tmp/nox_sim_linux
cp "$SIMULATOR" "$TMP_SIM" && chmod 755 "$TMP_SIM"

"$TMP_SIM" \
  -e "$OPENSBI_ELF" \
  -b "0x80200000:$KERNEL_IMG" \
  -b "0x87e00000:$DTB" \
  -s "$SIM_CYCLES" \
  -f "$WAVE_START"
