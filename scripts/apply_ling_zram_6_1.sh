#!/usr/bin/env bash
set -euo pipefail

# Enhanced ZRAM stack ported from LingLuo17/AnyKernel3, pinned for reproducibility.
# Target: Android 14 / Linux 6.1 GKID source tree.
LING_REPO="https://github.com/LingLuo17/AnyKernel3.git"
LING_REF="8a4919e5291d05fee0eb216ac11d1188fb5c7783"
SUKISU_PATCH_REPO="https://github.com/SukiSU-Ultra/SukiSU_patch.git"
SUKISU_PATCH_REF="547ae94bcaec53d030398f857950c64662043a5d"

if [[ ! -f Makefile || ! -d lib/lz4 || ! -d drivers/block/zram ]]; then
  echo "[-] Run this script from the kernel source root" >&2
  exit 1
fi

TMP_ROOT="${TMPDIR:-/tmp}/gkid-ling-zram"
LING_DIR="$TMP_ROOT/ling"
SUKI_DIR="$TMP_ROOT/sukisu-patch"
rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT"

fetch_commit() {
  local url="$1" ref="$2" dir="$3"
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch -q --depth=1 origin "$ref"
  git -C "$dir" checkout -q --detach FETCH_HEAD
}

echo "[*] Fetching pinned LingLuo ZRAM sources"
fetch_commit "$LING_REPO" "$LING_REF" "$LING_DIR"
echo "[*] Fetching pinned SukiSU ZRAM patches"
fetch_commit "$SUKISU_PATCH_REPO" "$SUKISU_PATCH_REF" "$SUKI_DIR"

echo "[*] Replacing LZ4 implementation with LingLuo ARM64-capable tree"
rm -f lib/lz4/lz4_compress.c lib/lz4/lz4_decompress.c lib/lz4/lz4defs.h lib/lz4/lz4hc_compress.c
cp -a "$LING_DIR/zram/lz4/." lib/lz4/
cp -a "$LING_DIR/zram/include/linux/." include/linux/

patch_neon_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -q "LZ4_arm64_decompress_safe" "$file" && return 0

  case "$file" in
    crypto/lz4.c|crypto/lz4hc.c)
      perl -i -pe '
        if (/int out_len = LZ4_decompress_safe\(src, dst, slen, \*dlen\);/) {
          $_ = "\tint out_len;\n\n"
             . "#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n"
             . "\tout_len = LZ4_arm64_decompress_safe(src, dst, slen, *dlen, false);\n"
             . "#else\n"
             . "\tout_len = LZ4_decompress_safe(src, dst, slen, *dlen);\n"
             . "#endif\n";
        }
      ' "$file"
      ;;
    fs/f2fs/compress.c)
      perl -i -0777 -pe '
        s{(\t)ret = LZ4_decompress_safe\(dic->cbuf->cdata, dic->rbuf,\s*\n\s*dic->clen, dic->rlen\);}
         {#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}ret = LZ4_arm64_decompress_safe(dic->cbuf->cdata, dic->rbuf,\n\t\t\t\t\t\tdic->clen, dic->rlen, false);\n#else\n${1}ret = LZ4_decompress_safe(dic->cbuf->cdata, dic->rbuf,\n\t\t\t\t\t\tdic->clen, dic->rlen);\n#endif}
      ' "$file"
      ;;
    fs/incfs/data_mgmt.c)
      perl -i -0777 -pe '
        s{(\t+)result = LZ4_decompress_safe\(src\.data, dst\.data, src\.len,\s*\n\s*dst\.len\);}
         {#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}result = LZ4_arm64_decompress_safe(src.data, dst.data, src.len, dst.len, false);\n#else\n${1}result = LZ4_decompress_safe(src.data, dst.data, src.len, dst.len);\n#endif}
      ' "$file"
      ;;
  esac

  if ! grep -q "LZ4_arm64_decompress_safe" "$file"; then
    echo "[-] NEON patch pattern not found in $file" >&2
    exit 1
  fi
}

patch_neon_file crypto/lz4.c
patch_neon_file crypto/lz4hc.c
patch_neon_file fs/f2fs/compress.c
patch_neon_file fs/incfs/data_mgmt.c

echo "[*] Adding LZ4K/LZ4KD/LZ4K_OPLUS sources"
cp -a "$SUKI_DIR/other/zram/lz4k/include/linux/." include/linux/
cp -a "$SUKI_DIR/other/zram/lz4k/lib/." lib/
cp -a "$SUKI_DIR/other/zram/lz4k/crypto/." crypto/
rm -rf lib/lz4k_oplus
cp -a "$SUKI_DIR/other/zram/lz4k_oplus" lib/

# The upstream LZ4KD patch also modifies module blacklisting. That behavior is
# unrelated to compression and changes module-loader semantics, so exclude it.
awk '/^diff -u a\/kernel\/module\/main.c b\/kernel\/module\/main.c/{exit} {print}' \
  "$SUKI_DIR/other/zram/zram_patch/6.1/lz4kd.patch" > "$TMP_ROOT/lz4kd-sanitized.patch"

for p in "$TMP_ROOT/lz4kd-sanitized.patch" "$SUKI_DIR/other/zram/zram_patch/6.1/lz4k_oplus.patch"; do
  echo "[*] Applying $(basename "$p")"
  if patch -p1 --dry-run -F 3 < "$p" >/dev/null; then
    patch -p1 -F 3 < "$p"
  else
    echo "[-] Patch does not apply cleanly: $p" >&2
    exit 1
  fi
done

grep -q "config CRYPTO_LZ4KD" crypto/Kconfig
grep -q "config ZRAM_DEF_COMP_LZ4K_OPLUS" drivers/block/zram/Kconfig
grep -q "LZ4_arm64_decompress_safe" lib/lz4/lz4.c

echo "[+] Enhanced LingLuo ZRAM stack applied"
