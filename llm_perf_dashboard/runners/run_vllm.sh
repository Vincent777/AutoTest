#!/usr/bin/env bash
# Ascend 上拉起 vLLM-Ascend（release tag），跑压测并入库。
# 用法:
#   ./run_vllm.sh [--tag TAG] [--model MODEL_ID] [--devices 0] [--port PORT]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common/lib.sh
source "${ROOT}/runners/common/lib.sh"

TAG=""
MODEL_ID=""
DEVICES="${ASCEND_RT_VISIBLE_DEVICES:-0}"
PORT=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --model) MODEL_ID="$2"; shift 2 ;;
    --devices) DEVICES="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [[ -z "$TAG" ]]; then
  TAG="$(python3 "${ROOT}/runners/common/resolve_release.py" --engine vllm --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["tag"])')"
fi

MODEL_META="$(python3 - <<PY
import yaml
from pathlib import Path
cfg = yaml.safe_load(Path("${ROOT}/configs/models.yaml").read_text())
models = [m for m in cfg["models"] if m.get("enabled", True)]
want = "${MODEL_ID}"
m = next((x for x in models if x["id"] == want), None) if want else models[0]
assert m, "no model"
print(m["id"])
print(m["path"])
print(m["served_model_name"])
print(m["tensor_parallel_size"])
print(m.get("max_model_len", 8192))
print(m.get("gpu_memory_utilization", 0.9))
print(m.get("vllm_extra_args", ""))
print(yaml.safe_load(Path("${ROOT}/configs/engines.yaml").read_text())["engines"]["vllm"]["image_repo"])
PY
)"

MODEL_ID="$(echo "$MODEL_META" | sed -n '1p')"
MODEL_PATH="$(echo "$MODEL_META" | sed -n '2p')"
SERVED_NAME="$(echo "$MODEL_META" | sed -n '3p')"
TP="$(echo "$MODEL_META" | sed -n '4p')"
MAX_LEN="$(echo "$MODEL_META" | sed -n '5p')"
GPU_UTIL="$(echo "$MODEL_META" | sed -n '6p')"
EXTRA_ARGS="$(echo "$MODEL_META" | sed -n '7p')"
IMAGE_REPO="$(echo "$MODEL_META" | sed -n '8p')"
IMAGE="${IMAGE_REPO}:${TAG}"

PORT="${PORT:-$(get_free_port 20000 20999)}"
SESSION="llm_perf_$(date +%Y%m%d_%H%M%S)"
CONTAINER="llm_perf_vllm_${SESSION}"
ART_DIR="${ROOT}/artifacts/${SESSION}_vllm_${MODEL_ID}"
mkdir -p "$ART_DIR"

log "engine=vllm tag=$TAG model=$MODEL_ID image=$IMAGE devices=$DEVICES port=$PORT"
log "artifacts=$ART_DIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY_RUN docker pull/run skipped"
  exit 0
fi

docker pull "$IMAGE"

stop_container "$CONTAINER"
# Ascend 容器参数与 ascend_test_suite 对齐（devices / privileged / weight mount）
docker run -d --name="$CONTAINER" \
  --privileged \
  --network=host \
  --device=/dev/davinci0 \
  --device=/dev/davinci_manager \
  --device=/dev/devmm_svm \
  --device=/dev/hisi_hdc \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
  -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
  -v /home/weight:/home/weight:ro \
  -v "${ART_DIR}:/artifacts" \
  -e ASCEND_RT_VISIBLE_DEVICES="$DEVICES" \
  "$IMAGE" \
  bash -lc "vllm serve ${MODEL_PATH} \
    --served-model-name ${SERVED_NAME} \
    --port ${PORT} \
    -tp ${TP} \
    --max-model-len ${MAX_LEN} \
    --gpu-memory-utilization ${GPU_UTIL} \
    ${EXTRA_ARGS} \
    > /artifacts/server.log 2>&1"

cleanup() {
  docker logs "$CONTAINER" > "${ART_DIR}/docker_logs.txt" 2>&1 || true
  stop_container "$CONTAINER"
}
trap cleanup EXIT

wait_openai_ready "127.0.0.1" "$PORT" 1800 10

bash "${ROOT}/runners/common/run_benchmark.sh" \
  --engine vllm \
  --engine-version "$TAG" \
  --model "$SERVED_NAME" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --tokenizer "$MODEL_PATH" \
  --out-dir "$ART_DIR"

RESULT_JSON="$(find "$ART_DIR" -name results.json | head -n 1)"
[[ -n "$RESULT_JSON" ]] || { log "ERROR: no results.json"; exit 1; }
python3 "${ROOT}/collector/ingest.py" "$RESULT_JSON" --db "${ROOT}/storage/perf.db"
log "done: $RESULT_JSON"
