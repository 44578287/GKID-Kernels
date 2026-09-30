#!/usr/bin/env bash
set -euo pipefail

OUT="${1:?out dir}"
KSRC="${2:?kernel source dir}"
ZIP="${3:?zip path}"
CFG="$OUT/.config"
IMG="$OUT/arch/arm64/boot/Image"

fail(){ echo "::error::$*"; exit 1; }
pass(){ echo "[MIN-AUDIT] PASS: $*"; }

[[ -s "$CFG" ]] || fail ".config missing"
[[ -s "$IMG" ]] || fail "Image missing"
[[ -s "$ZIP" ]] || fail "AnyKernel ZIP missing"

KR="$(cat "$OUT/include/config/kernel.release")"
[[ "$KR" == 6.1.138-android14-11-* ]] || fail "unexpected kernelrelease: $KR"
pass "kernelrelease=$KR"

grep -qx 'CONFIG_KSU=y' "$CFG" || fail "CONFIG_KSU is not y"
pass "CONFIG_KSU=y"

if grep -qx 'CONFIG_KPM=y' "$CFG"; then fail "KPM unexpectedly enabled"; fi
pass "KPM disabled"

if grep -q '^CONFIG_KSU_SUSFS=' "$CFG"; then fail "SUSFS unexpectedly present"; fi
pass "SUSFS absent"

for sym in CONFIG_BBG CONFIG_NTSYNC CONFIG_CRYPTO_LZ4K CONFIG_CRYPTO_LZ4KD CONFIG_CRYPTO_LZ4K_OPLUS; do
  if grep -q "^$sym=" "$CFG"; then fail "$sym unexpectedly present"; fi
done
pass "no BBG/NTSync/enhanced-ZRAM symbols"

grep -qx 'CONFIG_ZRAM=m' "$CFG" || fail "stock ZRAM was changed"
pass "stock CONFIG_ZRAM=m preserved"

# SukiSU main pinned revision currently exposes UAPI 4.
grep -q 'KERNEL_SU_UAPI_VERSION = 4' "$KSRC/KernelSU/uapi/supercall.h"   || fail "SukiSU UAPI 4 not found"
pass "SukiSU UAPI 4"

# Ensure the minimal build never picked up our extra shennong integration trees.
[[ ! -e "$KSRC/include/linux/lz4k.h" ]] || fail "LZ4K header unexpectedly present"
[[ ! -e "$KSRC/security/baseband-guard" ]] || fail "Baseband Guard unexpectedly present"
pass "extra integration trees absent"

echo "Image_SHA256=$(sha256sum "$IMG" | awk '{print $1}')"
echo "ZIP_SHA256=$(sha256sum "$ZIP" | awk '{print $1}')"
echo "MINIMAL_AUDIT_OK"
