#!/usr/bin/env python3
"""Compat patch for Ascend SGLang images where mooncake transfer_worker is newer
than AscendKVManager.send_kvcache.

Path note:
  - Source of truth lives in CI controller at
    /CI_Workspace/ci_autotest/ascend_test_suite/pd_ascend_send_kvcache_compat.py
    (entrypoint.sh clones/updates the repo under /CI_Workspace).
  - ascend_resource_monitor.sh scp's this file to each NPU host as
    /home/s_limingge/pd_ascend_send_kvcache_compat.py
  - SGLang inference containers only mount /home/s_limingge, NOT /CI_Workspace,
    so the in-container path must be /home/s_limingge/pd_ascend_send_kvcache_compat.py.

Symptom (quay.io/ascend/sglang:v0.5.17-*):
  TypeError: AscendKVManager.send_kvcache() got an unexpected keyword argument
  'dst_device_kv_indices'
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    try:
        import sglang.srt.disaggregation.ascend.conn as mod
    except Exception as exc:  # noqa: BLE001
        print(f"WARN: skip Ascend send_kvcache patch (import failed): {exc}")
        return 0

    path = Path(mod.__file__)
    text = path.read_text(encoding="utf-8")

    if re.search(
        r"def send_kvcache\([\s\S]*?dst_device_kv_indices[\s\S]*?\):",
        text,
    ):
        print(f"OK: {path} already accepts dst_device_kv_indices")
        return 0

    pattern = re.compile(
        r"(def send_kvcache\(\s*"
        r"self,\s*"
        r"mooncake_session_id:\s*str,\s*"
        r"prefill_kv_indices:[^,]+,\s*"
        r"dst_kv_ptrs:[^,]+,\s*"
        r"dst_kv_indices:[^,]+,\s*"
        r"executor:[^,]+,\s*)"
        r"(dst_layer_ids:[^=]+=\s*None,\s*)?"
        r"(\):)",
        re.M,
    )
    m = pattern.search(text)
    if not m:
        print(
            f"ERROR: could not locate AscendKVManager.send_kvcache signature in {path}",
            file=sys.stderr,
        )
        return 1

    # Accept and ignore newer mooncake kwargs (None for normal PD).
    insert = (
        m.group(1)
        + (m.group(2) or "dst_layer_ids=None,\n        ")
        + "dst_device_kv_indices=None,\n"
        + "        dst_kv_item_len=None,\n"
        + "        dst_attn_tp_size=None,\n"
        + "    ):"
    )
    path.write_text(text[: m.start()] + insert + text[m.end() :], encoding="utf-8")
    print(f"patched {path}: added dst_device_kv_indices compat kwargs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
