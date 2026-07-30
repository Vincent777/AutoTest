#!/usr/bin/env bash
# Ascend 上拉起 SGLang（release tag），跑压测并入库。
# 注意：SGLang Ascend 镜像仓库以 configs/engines.yaml 为准，需按机房实际镜像调整。
# 用法:
#   ./run_sglang.sh [--tag TAG] [--model MODEL_ID] [--devices 0] [--port PORT]
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
  TAG="$(python3 "${ROOT}/runners/common/resolve_release.py" --engine sglang --json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)[0];
import sys as _s
t=d.get("tag");
_s.exit(d.get("error","unknown")) if not t else print(t)')"
fi

MODEL_META="$(python3 - <<PY
import yaml
from pathlib import Path
cfg = yaml.safe_load(Path("${ROOT}/configs/models.yaml").read_text())
models = [m for m in cfg["models"] if m.get("enabled", True)]
want = "${MODEL_ID}"
m = next((x for x in models if x["id"] == want), None) if want else models[0]
assert m, "no model"
eng = yaml.safe_load(Path("${ROOT}/configs/engines.yaml").read_text())["engines"]["sglang"]
print(m["id"])
print(m["path"])
print(m["served_model_name"])
print(m["tensor_parallel_size"])
print(m.get("max_model_len", 8192))
print(m.get("sglang_extra_args", ""))
print(eng["image_repo"])
print(eng.get("image_tag_suffix", "cann9.0.0-910b"))
PY
)"

MODEL_ID="$(echo "$MODEL_META" | sed -n '1p')"
MODEL_PATH="$(echo "$MODEL_META" | sed -n '2p')"
SERVED_NAME="$(echo "$MODEL_META" | sed -n '3p')"
TP="$(echo "$MODEL_META" | sed -n '4p')"
MAX_LEN="$(echo "$MODEL_META" | sed -n '5p')"
EXTRA_ARGS="$(echo "$MODEL_META" | sed -n '6p')"
IMAGE_REPO="$(echo "$MODEL_META" | sed -n '7p')"
IMAGE_TAG_SUFFIX="$(echo "$MODEL_META" | sed -n '8p')"
if [[ "$TAG" == *cann* || "$TAG" == *910b* || "$TAG" == *a3* ]]; then
  IMAGE_TAG="$TAG"
else
  IMAGE_TAG="${TAG}-${IMAGE_TAG_SUFFIX}"
fi
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"

PORT="${PORT:-$(get_free_port 21000 21999)}"
SESSION="llm_perf_$(date +%Y%m%d_%H%M%S)"
CONTAINER="llm_perf_sglang_${SESSION}"
ART_DIR="${ROOT}/artifacts/${SESSION}_sglang_${MODEL_ID}"
mkdir -p "$ART_DIR"

log "engine=sglang tag=$TAG image_tag=$IMAGE_TAG model=$MODEL_ID image=$IMAGE devices=$DEVICES port=$PORT"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY_RUN docker pull/run skipped"
  exit 0
fi

docker pull "$IMAGE"

stop_container "$CONTAINER"
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
  bash -lc "python3 -m sglang.launch_server \
    --model-path ${MODEL_PATH} \
    --served-model-name ${SERVED_NAME} \
    --port ${PORT} \
    --tp-size ${TP} \
    --context-length ${MAX_LEN} \
    --host 0.0.0.0 \
    ${EXTRA_ARGS} \
    > /artifacts/server.log 2>&1"

cleanup() {
  docker logs "$CONTAINER" > "${ART_DIR}/docker_logs.txt" 2>&1 || true
  stop_container "$CONTAINER"
}
trap cleanup EXIT

wait_openai_ready "127.0.0.1" "$PORT" 1800 10

bash "${ROOT}/runners/common/run_benchmark.sh" \
  --engine sglang \
  --engine-version "$TAG" \
  --model "$SERVED_NAME" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --tokenizer "$MODEL_PATH" \
  --container "$CONTAINER" \
  --out-dir "$ART_DIR"

RESULT_JSON="$(find "$ART_DIR" -name results.json | head -n 1)"
[[ -n "$RESULT_JSON" ]] || { log "ERROR: no results.json"; exit 1; }
python3 "${ROOT}/collector/ingest.py" "$RESULT_JSON" --db "${ROOT}/storage/perf.db"
log "done: $RESULT_JSON"
