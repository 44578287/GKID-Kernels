#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${OUTDIR:-out}"
CFG="$OUTDIR/.config"
IMG="$OUTDIR/arch/arm64/boot/Image"
VMLINUX="$OUTDIR/vmlinux"

fail(){ echo "::error::$*"; exit 1; }
need_cfg(){ grep -qx "$1=y" "$CFG" || fail "missing config: $1=y"; }
LLVM_NM="$GITHUB_WORKSPACE/neutron-clang/bin/llvm-nm"
need_sym(){ [[ -x "$LLVM_NM" ]] || fail "llvm-nm not found: $LLVM_NM"; "$LLVM_NM" "$VMLINUX" | grep -qw "$1" || fail "missing symbol: $1"; }

[[ -s "$CFG" ]] || fail "missing .config"
[[ -s "$IMG" ]] || fail "missing Image"
[[ -s "$VMLINUX" ]] || fail "missing vmlinux"

need_cfg CONFIG_KSU
if [[ "${ENABLE_KPM:-true}" == "true" ]]; then need_cfg CONFIG_KPM; fi
if [[ "${KSU_SUSFS:-true}" == "true" ]]; then
  need_cfg CONFIG_KSU_SUSFS
  need_cfg CONFIG_KSU_SUSFS_SUS_MAP
  need_sym ksu_handle_post_execveat_sucompat
  need_sym ksu_install_su_fd
fi

case "${LTO:-fullLTO}" in
  fullLTO) need_cfg CONFIG_LTO_CLANG_FULL ;;
  thinLTO) need_cfg CONFIG_LTO_CLANG_THIN ;;
esac

if [[ "${ENABLE_LING_ZRAM:-true}" == "true" ]]; then
  need_cfg CONFIG_ZRAM
  need_cfg CONFIG_CRYPTO_LZ4
  need_cfg CONFIG_CRYPTO_LZ4K
  need_cfg CONFIG_CRYPTO_LZ4KD
  need_cfg CONFIG_CRYPTO_LZ4K_OPLUS
  strings "$IMG" | grep -q "lz4kd" || fail "Image lacks lz4kd marker"
  strings "$IMG" | grep -q "lz4k_oplus" || fail "Image lacks lz4k_oplus marker"
fi

if [[ "${ENABLE_NTSYNC:-true}" == "true" ]]; then need_cfg CONFIG_NTSYNC; fi
if [[ "${ENABLE_BBG:-true}" == "true" ]]; then need_cfg CONFIG_BBG; fi

if [[ "${ENABLE_SAFE_PROFILE:-true}" == "true" ]]; then
  grep -q 'freeze_timeout_msecs = 20 \* MSEC_PER_SEC' ksrc/kernel/power/process.c || fail "SAFE profile freeze timeout not restored"
  ! grep -q "Don't let anything in Android change the freeze timeout" ksrc/kernel/power/main.c || fail "SAFE profile still locks freeze timeout sysfs"
  grep -q '#define JBD2_DEFAULT_MAX_COMMIT_AGE 5' ksrc/include/linux/jbd2.h || fail "SAFE profile ext4 commit age not restored"
  grep -A3 '^bad_version:' ksrc/kernel/module/version.c | grep -q 'return 0;' || fail "SAFE profile module version check not restored"
fi

if find . -name '*.rej' -type f | grep -q .; then
  find . -name '*.rej' -type f -print
  fail "patch reject files exist"
fi

KR="$(make -s -C "$GITHUB_WORKSPACE/ksrc" O="$GITHUB_WORKSPACE/$OUTDIR" ARCH=arm64 kernelrelease)"
[[ "$KR" == 6.1.177-* ]] || fail "unexpected kernelrelease: $KR"

echo "AUDIT_OK kernelrelease=$KR"
