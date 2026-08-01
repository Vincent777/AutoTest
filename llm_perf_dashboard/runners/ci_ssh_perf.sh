#!/usr/bin/env bash
# 从 GitLab Runner 侧 SSH 到测试机执行（可选封装，逻辑与 .gitlab-ci.yml 一致）
#
# 用法:
#   CI_JOB_ID=... CI_COMMIT_BRANCH=main CI_COMMIT_SHORT_SHA=abc1234 \
#     bash runners/ci_ssh_perf.sh vLLM
#   bash runners/ci_ssh_perf.sh SGLang
set -euo pipefail

ENGINE="${1:?usage: $0 vLLM|SGLang}"
MODEL_LIST="${MODEL_LIST:-DeepSeek-R1-Distill-Qwen-32B}"
TEST_TYPE="${TEST_TYPE:-Smoke}"
TEST_HOST="${TEST_HOST:-ci_test@192.168.100.106}"
JOB_ID="${CI_JOB_ID:?CI_JOB_ID required}"
COMMIT_SHORT_SHA="${COMMIT_SHORT_SHA:-${CI_COMMIT_SHORT_SHA:?CI_COMMIT_SHORT_SHA required}}"
VERSION="${CI_COMMIT_BRANCH:?CI_COMMIT_BRANCH required}-${COMMIT_SHORT_SHA}"

echo "SSH perf: host=$TEST_HOST engine=$ENGINE models=$MODEL_LIST version=$VERSION"

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TEST_HOST" "
  set -m
  cd /home/ci_test
  if [ ! -d Ascend_910_Test ];then
    mkdir -p Ascend_910_Test
  fi
  cd Ascend_910_Test
  mkdir ${JOB_ID}
  cd ${JOB_ID}
  git init
  git remote add origin http://git.xcoresigma.com/xcore-sigma/autotest.git
  git fetch --depth=1 origin main
  git show origin/main:ascend_test_suite/daemon.sh > daemon.sh
  chmod a+x daemon.sh
  ./daemon.sh \
    ${TEST_TYPE} \
    ${ENGINE} \
    ${MODEL_LIST} \
    ${JOB_ID} \
    ${VERSION}
"
