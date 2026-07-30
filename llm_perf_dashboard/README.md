# LLM Perf Dashboard（Ascend）

挂在 `ci_autotest/llm_perf_dashboard`：定期对 **vLLM-Ascend** 与 **SGLang-Ascend** 的 **release tag** 做性能测试，结果入库并通过 WebUI 展示。GitLab Schedule 每周跑 1～2 次。

## 已拍板决策

| 项 | 选择 |
|----|------|
| 硬件 | Ascend 910B |
| 版本策略 | 只跟 release tag |
| Phase1 模型 | `DeepSeek-R1-Distill-Llama-8B`（70B 默认关闭） |
| 部署 | 现有 GitLab + `910_ascend` runner |
| 形态 | 本目录（不改动 `ascend_test_suite` 主流程） |

## 目录

```text
llm_perf_dashboard/
├── configs/          # engines / models / workloads / local
├── runners/          # resolve_release + run_vllm / run_sglang / run_weekly
├── collector/        # 统一 JSON → SQLite
├── api/              # FastAPI
├── web/              # 极简 WebUI（对比表 + 趋势图）
├── storage/perf.db   # 跑测后生成
├── artifacts/        # 原始日志与 results.json
└── .gitlab-ci.yml    # WeeklyPerf / PublishDashboard
```

## 快速开始

```bash
cd /home/s_limingge/ci_autotest/llm_perf_dashboard
python3 -m pip install -r requirements.txt

# 仅解析最新 release tag（需访问 GitHub API）
python3 runners/common/resolve_release.py --engine vllm --json

# 干跑（不拉镜像）
bash runners/run_vllm.sh --dry-run
bash runners/run_sglang.sh --dry-run

# 真跑（本机需有 NPU + Docker + 权重）
bash runners/run_vllm.sh --devices 0
bash runners/run_sglang.sh --devices 0
# 或
bash runners/run_weekly.sh

# 灌入示例数据，先看 UI
python3 collector/ingest.py collector/schema_example.json

# WebUI
python3 -m uvicorn api.main:app --host 0.0.0.0 --port 8088
# 浏览器打开 http://<host>:8088/
```

## GitLab

1. 在项目根 `.gitlab-ci.yml` 增加：

```yaml
include:
  - local: llm_perf_dashboard/.gitlab-ci.yml
```

若仓库本身就在 `ascend_test_suite` 子路径维护 CI，也可把 `WeeklyPerf-ascend` job 拷过去，或改 `CI_PROJECT_DIR` 路径。

2. **CI/CD → Schedules** 新建计划（建议每周 2 次），目标 job 会因 `rules: schedule` 自动跑 `WeeklyPerf-ascend`。
3. 变量：沿用现有 `TESTSERVER_SSH_KEY`；可选 `ENGINES=vllm` / `ASCEND_RT_VISIBLE_DEVICES=0,1`。

## 结果 Schema

见 `collector/schema_example.json`。入库字段包括吞吐、TTFT/TPOT、成功率，以及 `engine` / `engine_version` / `model` / `workload` / `concurrency`。

## 注意

- **SGLang Ascend 镜像**：`configs/engines.yaml` 中 `sglang.image_repo` 为占位，请改成机房实际可用镜像后再真跑。
- **vLLM 镜像**：默认 `quay.io/ascend/vllm-ascend:<release-tag>`，与现有 suite 一致。
- 设备挂载、`docker run` 参数可按节点差异再收紧；当前先对齐 `ascend_test_suite` 的常见挂载。
- WebUI 长期服务建议用 systemd，而不是只靠手动 CI job。

## 下一步（Phase 2）

- 接通 NPU 锁（复用 `npu_lock_manager_for_ci.sh`）
- 飞书摘要通知
- 70B 可选矩阵打开
- 失败重试与「相对上次 release 回归」标记
