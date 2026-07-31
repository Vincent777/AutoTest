# GitLab → CI/CD → Schedules 建议：
# - 每周一 / 周四跑 vLLM_Perf-aarch64-ascend、SGLang_Perf-aarch64-ascend
# - Cron 示例（UTC）：0 18 * * 1,4  （对应北京时间次日 02:00）
# - Target branch: main
# - Active: yes
#
# Runner tags:
# - 910_ascend_for_vllm_perf
# - 910_ascend_for_sglang_perf
#
# 根目录 include:
# include:
#   - local: llm_perf_dashboard/.gitlab-ci.yml
