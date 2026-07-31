#!/usr/bin/env bash
# 测试机本地入口：跑 SGLang（经 daemon.sh，参数对齐 GitLab CI）
#
# 用法:
#   ./run_sglang.sh [MODEL_LIST] [JOB_ID] [VERSION] [TEST_TYPE]
#
# 等价于 CI 中:
#   ./daemon.sh Smoke SGLang ${MODEL_LIST} ${CI_JOB_ID} ${BRANCH}-${SHA}
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common/lib.sh
source "${ROOT}/runners/common/lib.sh"

MODEL_LIST="${1:-${MODEL_LIST:-DeepSeek-R1-Distill-Qwen-32B}}"
JOB_ID="${2:-${JOB_ID:-${CI_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}}}"
VERSION="${3:-${VERSION:-${CI_COMMIT_BRANCH:-local}-${CI_COMMIT_SHORT_SHA:-dev}}}"
TEST_TYPE="${4:-${TEST_TYPE:-Smoke}}"

log "run_sglang MODEL_LIST=$MODEL_LIST JOB_ID=$JOB_ID VERSION=$VERSION TEST_TYPE=$TEST_TYPE"
run_daemon "$TEST_TYPE" "SGLang" "$MODEL_LIST" "$JOB_ID" "$VERSION"
log "run_sglang finished"
