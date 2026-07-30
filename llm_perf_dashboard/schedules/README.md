# 示例：如何在仓库根目录 include 本目录 CI（按需合并进项目现有 .gitlab-ci.yml）
# include:
#   - local: llm_perf_dashboard/.gitlab-ci.yml

# GitLab → CI/CD → Schedules 建议：
# - 每周一 02:00、每周四 02:00（UTC+8）跑 WeeklyPerf-ascend
# - Cron: 0 18 * * 1,4   （GitLab cron 多为 UTC：北京时间 02:00 = UTC 18:00 前一天）
# - Target branch: main
# - Active: yes
