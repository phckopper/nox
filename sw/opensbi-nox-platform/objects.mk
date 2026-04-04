# SPDX-License-Identifier: BSD-2-Clause
# NoX RV64 minimal OpenSBI platform

platform-cppflags-y =
platform-cflags-y   = -Os
platform-asflags-y  =
platform-ldflags-y  =

platform-objs-y += platform.o

# Only fw_jump — no fw_dynamic, no fw_payload
FW_JUMP=y
FW_JUMP_ADDR=0x80200000
FW_JUMP_FDT_ADDR=0x87e00000
