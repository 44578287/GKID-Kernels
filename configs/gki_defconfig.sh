#!/usr/bin/env bash

# Define target defconfig location
DEFCONFIG="arch/arm64/configs/gki_defconfig"

function apply_config(){
  cat "$1" >> "$2"
}

set_cfg_bool() {
  local name="$1"
  local value="$2"
  sed -i -E "/^${name}=|^# ${name} is not set$/d" "$DEFCONFIG"
  if [ "$value" = "y" ]; then
    echo "${name}=y" >> "$DEFCONFIG"
  else
    echo "# ${name} is not set" >> "$DEFCONFIG"
  fi
}

if [ "$KSU" != "no" ]; then
  echo "⚙️ Added KSU configuration"
  set_cfg_bool CONFIG_KSU y
  if [ "${ENABLE_KPM:-true}" = "true" ]; then
    set_cfg_bool CONFIG_KPM y
  else
    set_cfg_bool CONFIG_KPM n
  fi
fi

if [ "$KSU_SUSFS" = "true" ]; then
  echo "🔧 Mode: SuSFS Hook Enabled"
  apply_config "$WORKDIR/configs/susfs.config" "$DEFCONFIG"
fi

echo "⚙️ Adding Compatibility GKI Networking and Filesystem configs"
apply_config "$WORKDIR/configs/compat.config" "$DEFCONFIG"

echo "⚙️ Adding Universal Performance Tuning"
apply_config "$WORKDIR/configs/custom.config" "$DEFCONFIG"

if [ "${ENABLE_BBG:-true}" = "true" ]; then
  set_cfg_bool CONFIG_BBG y
else
  set_cfg_bool CONFIG_BBG n
fi

if [ "${ENABLE_NTSYNC:-true}" = "true" ]; then
  set_cfg_bool CONFIG_NTSYNC y
else
  set_cfg_bool CONFIG_NTSYNC n
fi

ZRAM_DEFAULT="${ZRAM_DEFAULT:-lz4}"
for cfg in \
  CONFIG_ZRAM_DEF_COMP_LZO \
  CONFIG_ZRAM_DEF_COMP_LZORLE \
  CONFIG_ZRAM_DEF_COMP_ZSTD \
  CONFIG_ZRAM_DEF_COMP_LZ4 \
  CONFIG_ZRAM_DEF_COMP_LZ4HC \
  CONFIG_ZRAM_DEF_COMP_LZ4K \
  CONFIG_ZRAM_DEF_COMP_LZ4KD \
  CONFIG_ZRAM_DEF_COMP_LZ4K_OPLUS \
  CONFIG_ZRAM_DEF_COMP_DEFLATE \
  CONFIG_ZRAM_DEF_COMP_842; do
  set_cfg_bool "$cfg" n
done

if [ "${ENABLE_LING_ZRAM:-true}" = "true" ]; then
  set_cfg_bool CONFIG_ZRAM y
  set_cfg_bool CONFIG_CRYPTO_LZ4 y
  set_cfg_bool CONFIG_CRYPTO_LZ4HC y
  set_cfg_bool CONFIG_CRYPTO_LZ4K y
  set_cfg_bool CONFIG_CRYPTO_LZ4KD y
  set_cfg_bool CONFIG_CRYPTO_LZ4K_OPLUS y

  case "$ZRAM_DEFAULT" in
    lz4)        set_cfg_bool CONFIG_ZRAM_DEF_COMP_LZ4 y ;;
    lz4hc)      set_cfg_bool CONFIG_ZRAM_DEF_COMP_LZ4HC y ;;
    lz4k)       set_cfg_bool CONFIG_ZRAM_DEF_COMP_LZ4K y ;;
    lz4kd)      set_cfg_bool CONFIG_ZRAM_DEF_COMP_LZ4KD y ;;
    lz4k_oplus) set_cfg_bool CONFIG_ZRAM_DEF_COMP_LZ4K_OPLUS y ;;
    *)
      echo "Unknown ZRAM_DEFAULT=$ZRAM_DEFAULT; falling back to lz4" >&2
      set_cfg_bool CONFIG_ZRAM_DEF_COMP_LZ4 y
      ;;
  esac
else
  set_cfg_bool CONFIG_ZRAM_DEF_COMP_LZ4 y
fi

if [ "$C_LTO" != "true" ]; then
  if [ "$KSU_COMPAT" = "true" ] || [ "$KSU" = "vnlto" ]; then
    LTO="noneLTO"
  fi
fi

case "$LTO" in
  thinLTO)
    echo "🔥 ThinLTO optimizations enabled"
    set_cfg_bool CONFIG_LTO_NONE n
    set_cfg_bool CONFIG_LTO_CLANG_THIN y
    set_cfg_bool CONFIG_LTO_CLANG_FULL n
    ;;
  fullLTO)
    echo "🔥 Full LTO optimizations enabled"
    set_cfg_bool CONFIG_LTO_NONE n
    set_cfg_bool CONFIG_LTO_CLANG_THIN n
    set_cfg_bool CONFIG_LTO_CLANG_FULL y
    ;;
  *)
    echo "ℹ️ LTO disabled or not specified"
    set_cfg_bool CONFIG_LTO_CLANG_THIN n
    set_cfg_bool CONFIG_LTO_CLANG_FULL n
    set_cfg_bool CONFIG_LTO_NONE y
    ;;
esac

if [ "$No_DS" = "true" ]; then
  export DROIDSPACES="false"
  export NH="false"
fi

if [ "$DROIDSPACES" = "true" ]; then
  echo "🐳 DroidSpaces support enabled"
  apply_config "$WORKDIR/configs/droidspaces.config" "$DEFCONFIG"
fi

if [ "$NH" = "true" ]; then
  echo "🐉 NetHunter support enabled"
  apply_config "$WORKDIR/configs/nethunter.config" "$DEFCONFIG"
fi

if [ "$KSU_COMPAT" != "true" ]; then
  echo "🔧 Disable useless debugging configs for performance and resources"
  set_cfg_bool CONFIG_RCU_TRACE n
fi
