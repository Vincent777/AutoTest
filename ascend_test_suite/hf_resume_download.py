#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Hugging Face 模型断点续传下载。

特点:
  - snapshot_download 自动跳过已下完的文件
  - 网络异常自动重试，直到成功或达到最大次数
  - 配合 nohup / screen 使用，SSH 断开不影响下载

示例:
  export HF_ENDPOINT=https://hf-mirror.com
  nohup python3 hf_resume_download.py \\
    --repo meta-llama/Meta-Llama-3.1-70B-Instruct \\
    --local-dir ./Meta-Llama-3.1-70B-Instruct \\
    --token YOUR_HF_TOKEN \\
    > download.log 2>&1 &

  # 查看进度
  tail -f download.log
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


def download_once(repo_id, local_dir, token, revision, max_workers):
    from huggingface_hub import snapshot_download

    kwargs = {
        "repo_id": repo_id,
        "local_dir": local_dir,
        "resume_download": True,
        "local_dir_use_symlinks": False,
    }
    if token:
        kwargs["token"] = token
    if revision:
        kwargs["revision"] = revision
    if max_workers is not None:
        kwargs["max_workers"] = max_workers

    # 兼容不同 huggingface_hub 版本的参数差异
    try:
        return snapshot_download(**kwargs)
    except TypeError:
        kwargs.pop("max_workers", None)
        kwargs.pop("local_dir_use_symlinks", None)
        try:
            return snapshot_download(**kwargs)
        except TypeError:
            kwargs.pop("resume_download", None)
            return snapshot_download(**kwargs)


def main():
    parser = argparse.ArgumentParser(description="HF model resume download with retry")
    parser.add_argument("--repo", required=True, help="repo id, e.g. meta-llama/Meta-Llama-3.1-70B-Instruct")
    parser.add_argument("--local-dir", required=True, help="local output directory")
    parser.add_argument("--token", default=os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN"),
                        help="HF token; also reads HF_TOKEN / HUGGING_FACE_HUB_TOKEN")
    parser.add_argument("--revision", default=None, help="branch/tag/commit, optional")
    parser.add_argument("--max-workers", type=int, default=4, help="parallel download workers (default: 4)")
    parser.add_argument("--max-retries", type=int, default=0,
                        help="max retry count; 0 means retry forever (default: 0)")
    parser.add_argument("--retry-wait", type=int, default=30, help="seconds to wait between retries (default: 30)")
    parser.add_argument("--endpoint", default=os.environ.get("HF_ENDPOINT"),
                        help="HF endpoint, e.g. https://hf-mirror.com")
    args = parser.parse_args()

    if args.endpoint:
        os.environ["HF_ENDPOINT"] = args.endpoint
        log("HF_ENDPOINT={}".format(os.environ["HF_ENDPOINT"]))

    local_dir = os.path.abspath(args.local_dir)
    os.makedirs(local_dir, exist_ok=True)

    attempt = 0
    while True:
        attempt += 1
        log("attempt #{} start: repo={} local_dir={}".format(attempt, args.repo, local_dir))
        try:
            path = download_once(
                repo_id=args.repo,
                local_dir=local_dir,
                token=args.token,
                revision=args.revision,
                max_workers=args.max_workers,
            )
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
            log("wait {}s then retry (resume from existing files)...".format(args.retry_wait))
            time.sleep(args.retry_wait)


if __name__ == "__main__":
    sys.exit(main())
