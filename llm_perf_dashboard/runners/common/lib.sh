#!/usr/bin/env bash
# 公共工具：与 GitLab CI 对齐的 daemon.sh 拉起方式
set -euo pipefail

log() { echo "[$(date '+%F %T')] $*"; }

: "${REMOTE_BASE:=${HOME}/Ascend_910_Test}"
: "${GIT_REMOTE:=http://git.xcoresigma.com/xcore-sigma/autotest.git}"
: "${GIT_REF:=main}"
: "${TEST_TYPE:=Smoke}"

prepare_job_dir() {
  local job_id="$1"
  local dir="${REMOTE_BASE}/${job_id}"
  mkdir -p "$dir"
  echo "$dir"
}

# 在目标目录取出 ascend_test_suite/daemon.sh（与 CI 相同）
fetch_daemon() {
  local work_dir="$1"
  (
    cd "$work_dir"
    if [[ ! -d .git ]]; then
      git init
    fi
    git remote remove origin 2>/dev/null || true
    git remote add origin "$GIT_REMOTE"
    git fetch --depth=1 origin "$GIT_REF"
    git show "origin/${GIT_REF}:ascend_test_suite/daemon.sh" > daemon.sh
    chmod a+x daemon.sh
  )
}

# 调用 daemon.sh（参数顺序与 .gitlab-ci.yml 一致）:
#   ./daemon.sh <TEST_TYPE> <ENGINE> <MODEL_LIST> <JOB_ID> <VERSION>
run_daemon() {
  local test_type="$1"
  local engine="$2"
  local model_list="$3"
  local job_id="$4"
  local version="$5"

  local work_dir
  work_dir="$(prepare_job_dir "$job_id")"
  log "work_dir=$work_dir test_type=$test_type engine=$engine models=$model_list version=$version"

  fetch_daemon "$work_dir"
  (
    cd "$work_dir"
    set -m
    ./daemon.sh \
      "$test_type" \
      "$engine" \
      "$model_list" \
      "$job_id" \
      "$version"
  )
}
