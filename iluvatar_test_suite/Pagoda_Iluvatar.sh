#!/usr/bin/env bash
# Pagoda_Iluvatar.sh — 天数智芯 SigInfer 一键入口（对齐 ascend Pagoda_910B*.py / hygon Pagoda_HYGON.sh）
#
# 用法:
#   ./Pagoda_Iluvatar.sh --test_type Service
#   ./Pagoda_Iluvatar.sh --test_type Performance
#
# 可选参数:
#   --model MODEL          模型名，默认 Qwen3-32B；也可用 default
#   --session_id ID        会话 ID，默认 000000
#   --test_param PARAM     Performance 默认 Random（或 SharedGPT）；Service 忽略
#   --version TAG          SigInfer 镜像 tag，默认 latest
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR"

TEST_TYPE="Service"
MODEL="Qwen3-32B"
SESSION_ID="000000"
TEST_PARAM=""
VERSION="main-4268c159"

usage() {
    cat <<'EOF'
Pagoda_Iluvatar.sh — 天数智芯 SigInfer 一键入口（对齐 ascend Pagoda_910B*.py）

用法:
  ./Pagoda_Iluvatar.sh --test_type Service
  ./Pagoda_Iluvatar.sh --test_type Performance

可选参数:
  --model MODEL          模型名，默认 Qwen3-32B；也可用 default
  --session_id ID        会话 ID，默认 000000
  --test_param PARAM     Performance 默认 Random（或 SharedGPT）；Service 忽略
  --version TAG          SigInfer 镜像 tag，默认 latest
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test_type)
            TEST_TYPE="${2:-}"
            shift 2
            ;;
        --model)
            MODEL="${2:-}"
            shift 2
            ;;
        --session_id)
            SESSION_ID="${2:-}"
            shift 2
            ;;
        --test_param)
            TEST_PARAM="${2:-}"
            shift 2
            ;;
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ "$TEST_TYPE" != "Service" && "$TEST_TYPE" != "Performance" ]]; then
    echo "ERROR: --test_type must be Service or Performance (got: $TEST_TYPE)"
    exit 1
fi

# 与 ascend Pagoda 一致：Service -> Stability；Performance -> Performance + Random
if [[ "$TEST_TYPE" == "Service" ]]; then
    MONITOR_TYPE="Stability"
    EXTRA_ARGS=()
else
    MONITOR_TYPE="Performance"
    if [[ -z "$TEST_PARAM" ]]; then
        TEST_PARAM="Random"
    fi
    EXTRA_ARGS=("$TEST_PARAM")
fi

CFG_VERSION="${VERSION:-latest}"
mkdir -p "$SCRIPT_DIR/$CFG_VERSION"
if [[ -f "$SCRIPT_DIR/latest/SigInfer_model_list.xlsx" ]]; then
    cp -f "$SCRIPT_DIR/latest/SigInfer_model_list.xlsx" "$SCRIPT_DIR/$CFG_VERSION/SigInfer_model_list.xlsx"
fi

MONITOR="$SCRIPT_DIR/iluvatar_resource_monitor.sh"
chmod +x "$MONITOR" "$SCRIPT_DIR/siginfer_iluvatar_test.sh" 2>/dev/null || true

echo "========================================"
echo " Pagoda Iluvatar / SigInfer"
echo " test_type : $TEST_TYPE (-> $MONITOR_TYPE)"
echo " model     : $MODEL"
echo " session   : $SESSION_ID"
echo " test_param: ${TEST_PARAM:-<n/a>}"
echo " version   : ${VERSION:-<latest main-*>}"
echo "========================================"

cleanup() {
    echo "Shutting down Pagoda_Iluvatar..."
    if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill -TERM -"$MONITOR_PID" 2>/dev/null || kill -TERM "$MONITOR_PID" 2>/dev/null || true
        sleep 5
        kill -KILL -"$MONITOR_PID" 2>/dev/null || kill -KILL "$MONITOR_PID" 2>/dev/null || true
    fi
    echo "inference engine terminated."
    exit 0
}

trap cleanup INT TERM

set +e
# 对齐 ascend: bash iluvatar_resource_monitor.sh <Stability|Performance> SigInfer <model> <session> [Random] [version]
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    setsid bash "$MONITOR" "$MONITOR_TYPE" "SigInfer" "$MODEL" "$SESSION_ID" "${EXTRA_ARGS[@]}" "$VERSION" &
else
    setsid bash "$MONITOR" "$MONITOR_TYPE" "SigInfer" "$MODEL" "$SESSION_ID" "$VERSION" &
fi
MONITOR_PID=$!
wait "$MONITOR_PID"
EXIT_CODE=$?
set -e

exit "$EXIT_CODE"
