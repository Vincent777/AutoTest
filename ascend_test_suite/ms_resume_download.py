#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ModelScope SDK 下载（仅建议 Python >= 3.8）。

当前环境若是 Python 3.7，请改用:
  ./ms_resume_download.sh start LLM-Research/Meta-Llama-3.1-70B-Instruct ./Meta-Llama-3.1-70B-Instruct

该 shell 方案走 git+lfs，兼容 Python 3.7，并支持断点续传。
"""

from __future__ import print_function

import argparse
import os
import sys
import time
import traceback
from datetime import datetime


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("[{}] {}".format(ts, msg))
    sys.stdout.flush()


def check_python():
    if sys.version_info < (3, 8):
        log("ERROR: Python {}.{}.{} 过旧，新版 modelscope 会报 invalid syntax".format(
            sys.version_info[0], sys.version_info[1], sys.version_info[2]))
        log("请改用: bash ms_resume_download.sh start <model_id> <local_dir>")
        return False
    return True


def download_once(model_id, local_dir, revision, cache_dir):
    from modelscope.hub.snapshot_download import snapshot_download

    kwargs = {
        "model_id": model_id,
        "local_dir": local_dir,
    }
    if revision:
        kwargs["revision"] = revision
    if cache_dir:
        kwargs["cache_dir"] = cache_dir

    try:
        return snapshot_download(**kwargs)
    except TypeError:
        kwargs.pop("local_dir", None)
        if cache_dir is None:
            kwargs["cache_dir"] = local_dir
        return snapshot_download(**kwargs)


def main():
    parser = argparse.ArgumentParser(description="ModelScope SDK resume download (Python>=3.8)")
    parser.add_argument("--model", required=True)
    parser.add_argument("--local-dir", required=True)
    parser.add_argument("--revision", default=None)
    parser.add_argument("--cache-dir", default=None)
    parser.add_argument("--max-retries", type=int, default=0)
    parser.add_argument("--retry-wait", type=int, default=30)
    args = parser.parse_args()

    if not check_python():
        return 2

    local_dir = os.path.abspath(args.local_dir)
    os.makedirs(local_dir, exist_ok=True)

    attempt = 0
    while True:
        attempt += 1
        log("attempt #{} start: model={} local_dir={}".format(attempt, args.model, local_dir))
        try:
            path = download_once(args.model, local_dir, args.revision, args.cache_dir)
            log("SUCCESS: downloaded to {}".format(path))
            return 0
        except KeyboardInterrupt:
            log("interrupted by user; already downloaded files are kept for resume")
            return 130
        except Exception as exc:
            log("FAILED: {}".format(exc))
            traceback.print_exc()
            if args.max_retries > 0 and attempt >= args.max_retries:
                log("reached max retries ({}), exit".format(args.max_retries))
                return 1
            log("wait {}s then retry...".format(args.retry_wait))
            time.sleep(args.retry_wait)


if __name__ == "__main__":
    sys.exit(main())
