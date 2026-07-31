# LLM Perf Dashboard（Ascend）

挂在 `ci_autotest/llm_perf_dashboard`：经 GitLab CI SSH 到测试机，调用 `ascend_test_suite/daemon.sh` 分别跑 **vLLM** / **SGLang** 性能；结果可入库并通过 WebUI 展示。

## 已拍板决策

| 项 | 选择 |
|----|------|
| 硬件 | Ascend 910 |
| 触发 | GitLab CI（Schedule / 手动） |
| Phase1 模型 | `DeepSeek-R1-Distill-Qwen-32B` |
| 远程执行 | `ci_test@192.168.100.106` → `daemon.sh` |
| Runner tags | `910_ascend_for_vllm_perf` / `910_ascend_for_sglang_perf` |

## 目录

```text
llm_perf_dashboard/
├── configs/          # engines / models / workloads / local
├── runners/          # run_vllm / run_sglang / run_weekly / ci_ssh_perf
├── collector/        # Excel/JSON → SQLite
├── api/              # FastAPI
├── web/              # WebUI（Trend + 筛选）
├── storage/perf.db
└── .gitlab-ci.yml    # vLLM_Perf / SGLang_Perf
```

## GitLab CI

根目录已 include：

```yaml
include:
  - local: llm_perf_dashboard/.gitlab-ci.yml
```

两个并行 job（设计对齐机房模板）：

1. `vLLM_Perf-aarch64-ascend` → `./daemon.sh Smoke vLLM ...`
2. `SGLang_Perf-aarch64-ascend` → `./daemon.sh Smoke SGLang ...`

远程步骤概要：

```bash
cd /home/ci_test/Ascend_910_Test/${CI_JOB_ID}
git fetch → 取出 ascend_test_suite/daemon.sh
./daemon.sh Smoke <vLLM|SGLang> ${MODEL_LIST} ${CI_JOB_ID} ${BRANCH}-${SHA}
```

变量：沿用 `TESTSERVER_SSH_KEY`；可改 job 内 `MODEL_LIST`。

## 测试机本地跑

```bash
cd /home/s_limingge/ci_autotest/llm_perf_dashboard
bash runners/run_vllm.sh    # 或 run_sglang.sh / run_weekly.sh
```

## WebUI

```bash
python3 -m pip install -r requirements.txt
python3 collector/ingest.py collector/schema_example.json
bash scripts/start_dashboard.sh
# http://<host>:8088/
```

Excel 报告转 JSON 入库：

```bash
python3 collector/excel_to_json.py /path/to/report.xlsx --ingest
```

## 注意

- `daemon.sh` 参数顺序必须与 `.gitlab-ci.yml` 保持一致。
- 当前仓库内 `ascend_test_suite/daemon.sh` 若与远程 `main` 参数个数不一致，以 **远程 git show 拉到的 daemon.sh** 为准（CI 就是这样取的）。
- WebUI 长期服务建议用 systemd。
