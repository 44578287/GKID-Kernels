#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
KSRC="$ROOT/ksrc"
OUT="$ROOT/out"
ART="$ROOT/artifacts"
AK3="$ROOT/anykernel"

KERNEL_REPO="https://github.com/ahmed-alnassif/GKI-Duchamp-6.1"
KERNEL_REF="9e207186c74578f0ef1872467740ab30f74abe6d"
EXPECTED_KERNEL="6.1.138"

SUKISU_REPO="SukiSU-Ultra/SukiSU-Ultra"
SUKISU_REF="7fbbb1f12e2410b69c8ebf958be84f165b8d0c93"

CLANG_VERSION="r487747c"
CLANG_DIR="$ROOT/clang-$CLANG_VERSION"
CLANG_ARCHIVE="$ROOT/clang-$CLANG_VERSION.tar.gz"
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android14-release/clang-$CLANG_VERSION.tar.gz"

ANYKERNEL_REPO="https://github.com/ahmed-alnassif/AK3-GKID"
RUN_NUM="${GITHUB_RUN_NUMBER:-0}"

rm -rf "$KSRC" "$OUT" "$AK3" "$CLANG_DIR"
mkdir -p "$ART" "$CLANG_DIR"
exec > >(tee "$ART/minimal-build.log") 2>&1

echo "=== shennong minimal 6.1.138 build ==="
echo "kernel_ref=$KERNEL_REF"
echo "sukisu_ref=$SUKISU_REF"
echo "clang=$CLANG_VERSION"

echo "[1/7] Fetch clean Android14 Linux 6.1.138 baseline"
git init -q "$KSRC"
git -C "$KSRC" remote add origin "$KERNEL_REPO"
git -C "$KSRC" fetch -q --depth=1 origin "$KERNEL_REF"
git -C "$KSRC" checkout -q --detach FETCH_HEAD

LINUX_VERSION="$(make -s -C "$KSRC" kernelversion)"
[[ "$LINUX_VERSION" == "$EXPECTED_KERNEL" ]] || {
  echo "::error::Expected $EXPECTED_KERNEL, got $LINUX_VERSION"
  exit 1
}
grep -qx 'CLANG_VERSION=r487747c' "$KSRC/build.config.constants" || {
  echo "::error::6.1.138 source does not request clang-r487747c"
  exit 1
}

echo "[2/7] Fetch exact Android 14 clang-r487747c"
curl --fail -L --retry 4 --retry-delay 3 "$CLANG_URL" -o "$CLANG_ARCHIVE"
tar -xzf "$CLANG_ARCHIVE" -C "$CLANG_DIR"
rm -f "$CLANG_ARCHIVE"
export PATH="$CLANG_DIR/bin:$PATH"
clang --version | head -n 2
clang --version | grep -q '17.0.2' || {
  echo "::error::Unexpected clang version"
  exit 1
}

echo "[3/7] Add ONLY SukiSU Ultra root"
cd "$KSRC"
curl --fail -L --retry 4   "https://raw.githubusercontent.com/$SUKISU_REPO/$SUKISU_REF/kernel/setup.sh"   | sh -s "$SUKISU_REF"

# Root only. Keep manager integration. Explicitly keep KPM/debug off.
make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 gki_defconfig
scripts/config --file "$OUT/.config" --enable KSU
scripts/config --file "$OUT/.config" --disable KPM
scripts/config --file "$OUT/.config" --disable KSU_DEBUG
scripts/config --file "$OUT/.config" --disable KSU_DISABLE_MANAGER
scripts/config --file "$OUT/.config" --set-str LOCALVERSION "-android14-11-gkid-minimal-r$RUN_NUM-4k" || true
scripts/config --file "$OUT/.config" --set-str CONFIG_LOCALVERSION "-android14-11-gkid-minimal-r$RUN_NUM-4k"
scripts/config --file "$OUT/.config" --disable CONFIG_LOCALVERSION_AUTO
make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig

echo "[4/7] Pre-build minimality audit"
grep -qx 'CONFIG_KSU=y' "$OUT/.config"
! grep -qx 'CONFIG_KPM=y' "$OUT/.config"
! grep -qx 'CONFIG_KSU_DEBUG=y' "$OUT/.config"
! grep -q '^CONFIG_KSU_SUSFS=' "$OUT/.config"
! grep -q '^CONFIG_BBG=' "$OUT/.config"
! grep -q '^CONFIG_NTSYNC=' "$OUT/.config"
! grep -q '^CONFIG_CRYPTO_LZ4K=' "$OUT/.config"
! grep -q '^CONFIG_CRYPTO_LZ4KD=' "$OUT/.config"
! grep -q '^CONFIG_CRYPTO_LZ4K_OPLUS=' "$OUT/.config"

# Stock Android14 GKI baseline has ZRAM as a module; do not replace or tune it.
grep -qx 'CONFIG_ZRAM=m' "$OUT/.config"

git status --short > "$ART/minimal-source-status.txt"
git diff -- drivers/Kconfig drivers/Makefile > "$ART/minimal-source-diff.patch"
cp "$OUT/.config" "$ART/minimal.config"

echo "[5/7] Build"
export KBUILD_BUILD_USER="build-user"
export KBUILD_BUILD_HOST="build-host"
export KBUILD_BUILD_TIMESTAMP="$(git -C "$KSRC" log -1 --format=%cd --date=format-local:'%a %b %d %T UTC %Y')"
export KCFLAGS="-D__ANDROID_COMMON_KERNEL__"

make -C "$KSRC" O="$OUT"   ARCH=arm64 LLVM=1 LLVM_IAS=1   CC=clang HOSTCC=clang HOSTCXX=clang++   LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip   OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf   -j"$(nproc)"

IMAGE="$OUT/arch/arm64/boot/Image"
[[ -s "$IMAGE" ]] || { echo "::error::Image missing"; exit 1; }

echo "[6/7] Package AnyKernel"
cd "$ROOT"
git clone -q --depth=1 "$ANYKERNEL_REPO" "$AK3"
cp "$IMAGE" "$AK3/Image"
sed -i   -e "s/kernel.string=.*/kernel.string=GKID Minimal 6.1.138 + SukiSU Ultra/"   -e 's/supported_kernel=".*"/supported_kernel="6.1"/'   "$AK3/anykernel.sh"

ZIP="$ART/GKID-Minimal-SukiSU-6.1.138-r$RUN_NUM.zip"
(
  cd "$AK3"
  zip -q -r9 "$ZIP" .
)

echo "[7/7] Final audit"
"$ROOT/scripts/audit_shennong_minimal.sh" "$OUT" "$KSRC" "$ZIP" | tee "$ART/minimal-audit.txt"

echo "MINIMAL_BUILD_OK"
echo "artifact=$ZIP"
