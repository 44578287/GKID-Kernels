#!/usr/bin/env bash
set -euo pipefail

# Shennong SAFE profile for the pinned Android14 / Linux 6.1.138 baseline.
# Keep GKID's vendor-module compatibility behavior by default. The stock
# 6.1.138 baseline already uses a 20s freezer timeout and 5s JBD2 commit age,
# so those checks are idempotent.

python3 - <<'PY'
from pathlib import Path
import os

def normalize(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    if new in s:
        print(f"[SAFE] {label}: already correct")
        return
    if old not in s:
        raise SystemExit(f"{label}: neither expected old nor target pattern found in {path}")
    p.write_text(s.replace(old, new, 1))
    print(f"[SAFE] {label}: normalized")

if os.environ.get("ENABLE_STRICT_MODULE_CRC", "false").lower() == "true":
    normalize(
        "kernel/module/version.c",
        'pr_warn("%s: disagrees about version of symbol %s, but ignore...\\n", info->name, symname);\n\treturn 1;',
        'pr_warn("%s: disagrees about version of symbol %s\\n", info->name, symname);\n\treturn 0;',
        "strict module CRC",
    )

normalize(
    "kernel/power/process.c",
    "unsigned int __read_mostly freeze_timeout_msecs = MSEC_PER_SEC;",
    "unsigned int __read_mostly freeze_timeout_msecs = 20 * MSEC_PER_SEC;",
    "freeze timeout 20s",
)

p = Path("kernel/power/main.c")
s = p.read_text()
lock = "\t/* Don't let anything in Android change the freeze timeout */\n\treturn n;\n\n"
if lock in s:
    p.write_text(s.replace(lock, "", 1))
    print("[SAFE] freeze timeout sysfs: unlocked")
else:
    print("[SAFE] freeze timeout sysfs: already unlocked")

normalize(
    "include/linux/jbd2.h",
    "#define JBD2_DEFAULT_MAX_COMMIT_AGE 30",
    "#define JBD2_DEFAULT_MAX_COMMIT_AGE 5",
    "JBD2 commit age 5s",
)
PY

echo "[+] Shennong SAFE profile applied"
