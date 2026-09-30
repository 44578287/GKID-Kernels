#!/usr/bin/env bash
set -euo pipefail

# Shennong SAFE profile: keep GKID's vendor-module compatibility behavior by
# default, while restoring suspend/journal semantics that are risky on shennong.
# Strict module CRC rejection is optional because GKID intentionally ignores
# symbol-version mismatches for cross-build GKI vendor-module compatibility.

python3 - <<'PY'
from pathlib import Path

def replace_once(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"{label}: expected source pattern not found in {path}")
    p.write_text(s.replace(old, new, 1))

if __import__("os").environ.get("ENABLE_STRICT_MODULE_CRC", "false").lower() == "true":
    replace_once(
        "kernel/module/version.c",
        'pr_warn("%s: disagrees about version of symbol %s, but ignore...\\n", info->name, symname);\n\treturn 1;',
        'pr_warn("%s: disagrees about version of symbol %s\\n", info->name, symname);\n\treturn 0;',
        "module-version-check",
    )

replace_once(
    "kernel/power/process.c",
    "unsigned int __read_mostly freeze_timeout_msecs = MSEC_PER_SEC;",
    "unsigned int __read_mostly freeze_timeout_msecs = 20 * MSEC_PER_SEC;",
    "freeze-timeout",
)

replace_once(
    "kernel/power/main.c",
    '\t/* Don\'t let anything in Android change the freeze timeout */\n\treturn n;\n\n',
    "",
    "freeze-timeout-sysfs",
)

replace_once(
    "include/linux/jbd2.h",
    "#define JBD2_DEFAULT_MAX_COMMIT_AGE 30",
    "#define JBD2_DEFAULT_MAX_COMMIT_AGE 5",
    "ext4-commit-age",
)
PY

echo "[+] Shennong SAFE profile applied"
