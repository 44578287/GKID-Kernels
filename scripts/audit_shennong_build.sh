#!/usr/bin/env bash
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUTDIR="${OUTDIR:-out}"
CFG="$ROOT/$OUTDIR/.config"
IMG="$ROOT/$OUTDIR/arch/arm64/boot/Image"
VMLINUX="$ROOT/$OUTDIR/vmlinux"
KREL="$ROOT/$OUTDIR/include/config/kernel.release"
LLVM_NM="$ROOT/neutron-clang/bin/llvm-nm"
REPORT="$ROOT/artifacts/audit-shennong.txt"
NM_DUMP="$ROOT/$OUTDIR/vmlinux.nm.audit"

mkdir -p "$ROOT/artifacts"
: > "$REPORT"
exec > >(tee -a "$REPORT") 2>&1

fail(){ echo "::error::$*"; exit 1; }
pass(){ echo "[AUDIT] PASS: $*"; }
need_cfg(){
  grep -qx "$1=y" "$CFG" || fail "missing config: $1=y"
  pass "$1=y"
}
need_cfg_line(){
  grep -qxF "$1" "$CFG" || fail "missing config line: $1"
  pass "$1"
}
need_not_cfg(){
  if grep -qx "$1=y" "$CFG"; then fail "unexpected config: $1=y"; fi
  pass "$1 is not enabled"
}
need_sym(){
  grep -Eq "[[:space:]]$1$" "$NM_DUMP" || fail "missing symbol: $1"
  pass "symbol $1"
}

echo "=== Shennong post-build audit ==="
date -u +"UTC=%Y-%m-%dT%H:%M:%SZ"

[[ -s "$CFG" ]] || fail "missing .config"
[[ -s "$IMG" ]] || fail "missing Image"
[[ -s "$VMLINUX" ]] || fail "missing vmlinux"
[[ -s "$KREL" ]] || fail "missing kernel.release"
[[ -x "$LLVM_NM" ]] || fail "llvm-nm not found: $LLVM_NM"

# Generate the symbol listing once. Do not pipe llvm-nm into grep -q under
# pipefail: grep exits early on a match and llvm-nm then gets SIGPIPE.
"$LLVM_NM" "$VMLINUX" > "$NM_DUMP"
pass "vmlinux symbol table generated"

need_cfg CONFIG_KSU
if [[ "${ENABLE_KPM:-true}" == "true" ]]; then need_cfg CONFIG_KPM; fi

if [[ "${KSU_SUSFS:-true}" == "true" ]]; then
  for cfg in \
    CONFIG_KSU_SUSFS \
    CONFIG_KSU_SUSFS_SUS_PATH \
    CONFIG_KSU_SUSFS_SUS_MOUNT \
    CONFIG_KSU_SUSFS_SUS_KSTAT \
    CONFIG_KSU_SUSFS_SUS_MAP \
    CONFIG_KSU_SUSFS_OPEN_REDIRECT; do
    need_cfg "$cfg"
  done
  need_sym ksu_handle_post_execveat_sucompat
  need_sym ksu_install_su_fd

  grep -qF 'DECLARE(__u32, KERNEL_SU_UAPI_VERSION, 4);' "$ROOT/ksrc/KernelSU/kernel/include/uapi/supercall.h" \
    || fail "SukiSU kernel UAPI is not v4"
  pass "SukiSU kernel UAPI v4"
fi

case "${LTO:-fullLTO}" in
  fullLTO) need_cfg CONFIG_LTO_CLANG_FULL ;;
  thinLTO) need_cfg CONFIG_LTO_CLANG_THIN ;;
  noneLTO) need_cfg CONFIG_LTO_NONE ;;
esac

need_cfg_line 'CONFIG_HZ=300'
need_cfg CONFIG_LRU_GEN
need_cfg CONFIG_DEFAULT_BBR
need_cfg CONFIG_TCP_CONG_BBR
need_cfg CONFIG_NET_SCH_FQ

if [[ "${ENABLE_LING_ZRAM:-true}" == "true" ]]; then
  for cfg in \
    CONFIG_ZRAM \
    CONFIG_ZRAM_WRITEBACK \
    CONFIG_ZRAM_MEMORY_TRACKING \
    CONFIG_CRYPTO_LZ4 \
    CONFIG_CRYPTO_LZ4HC \
    CONFIG_CRYPTO_LZ4K \
    CONFIG_CRYPTO_LZ4KD \
    CONFIG_CRYPTO_LZ4K_OPLUS; do
    need_cfg "$cfg"
  done

  case "${ZRAM_DEFAULT:-lz4}" in
    lz4) need_cfg_line 'CONFIG_ZRAM_DEF_COMP="lz4"' ;;
    *) pass "non-lz4 default compressor selected by workflow: ${ZRAM_DEFAULT:-}" ;;
  esac

  grep -aFq "lz4kd" "$IMG" || fail "Image lacks lz4kd marker"
  grep -aFq "lz4k_oplus" "$IMG" || fail "Image lacks lz4k_oplus marker"
  pass "enhanced ZRAM markers present in Image"
fi

if [[ "${ENABLE_NTSYNC:-true}" == "true" ]]; then need_cfg CONFIG_NTSYNC; fi
if [[ "${ENABLE_BBG:-true}" == "true" ]]; then need_cfg CONFIG_BBG; fi

if [[ "${ENABLE_SAFE_PROFILE:-true}" == "true" ]]; then
  python3 - <<'PY'
from pathlib import Path

checks = [
    ("ksrc/kernel/power/process.c",
     "unsigned int __read_mostly freeze_timeout_msecs = 20 * MSEC_PER_SEC;",
     True, "freeze timeout restored to 20s"),
    ("ksrc/kernel/power/main.c",
     "Don't let anything in Android change the freeze timeout",
     False, "freeze-timeout sysfs is not hard-locked"),
    ("ksrc/include/linux/jbd2.h",
     "#define JBD2_DEFAULT_MAX_COMMIT_AGE 5",
     True, "ext4/JBD2 commit age restored to 5s"),
]
for path, needle, expected, label in checks:
    data = Path(path).read_text()
    present = needle in data
    if present != expected:
        raise SystemExit(f"SAFE profile check failed: {label}")
    print(f"[AUDIT] PASS: {label}")

print("[AUDIT] INFO: module version policy validated by build profile")
PY
fi

mapfile -t REJECTS < <(find "$ROOT" -name '*.rej' -type f -print)
if (( ${#REJECTS[@]} )); then
  printf '%s\n' "${REJECTS[@]}"
  fail "patch reject files exist"
fi
pass "no patch reject files"

KR="$(cat "$KREL")"
[[ "$KR" == 6.1.177-* ]] || fail "unexpected kernelrelease: $KR"
pass "kernelrelease=$KR"

echo "Image_SHA256=$(sha256sum "$IMG" | awk '{print $1}')"
echo "AUDIT_OK kernelrelease=$KR"
