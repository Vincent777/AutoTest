#!/usr/bin/env bash
# Launch PD router/proxy after all Prefill/Decode nodes registered in server_config.
set -euo pipefail

ENGINE="${1:?ENGINE}"
TEST_TYPE="${2:?TEST_TYPE}"
SESSION_ID="${3:?SESSION_ID}"
JOB_COUNT="${4:?JOB_COUNT}"
MODEL="${5:?MODEL}"
VERSION="${6:?VERSION}"
COORD_SSH_HOST="${7:?COORD_SSH_HOST}"
COORD_LOCAL_IP="${8:?COORD_LOCAL_IP}"
JOB_ID="${9:?JOB_ID}"
TOPOLOGY="${10:?TOPOLOGY}"

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOCK_DIR="/home/s_limingge/.npu_locks"
PROXY_PORT_START="${PD_PROXY_PORT_START:-28000}"
PROXY_PORT_RANGE="${PD_PROXY_PORT_RANGE:-2000}"
ROUTER_TIMEOUT="${PD_ROUTER_STARTUP_TIMEOUT:-300}"
SGLANG_NPU_TAG_SUFFIX="${SGLANG_NPU_TAG_SUFFIX:-cann9.0.0-910b}"

resolve_image_tag() {
    local ver="$1"
    if [[ "$ver" == *cann* || "$ver" == *910b* || "$ver" == *a3* ]]; then
        echo "$ver"
    else
        echo "${ver}-${SGLANG_NPU_TAG_SUFFIX}"
    fi
}

pick_free_port() {
    local seed="$1"
    local port=$((PROXY_PORT_START + seed % PROXY_PORT_RANGE))
    local tries=0
    while [ "$tries" -lt "$PROXY_PORT_RANGE" ]; do
        if ! ssh -q -o ConnectionAttempts=3 "s_limingge@${COORD_SSH_HOST}" \
            "ss -ltn 2>/dev/null | awk '{print \$4}' | grep -q ':${port}\$'"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
        tries=$((tries + 1))
    done
    echo "ERROR: no free proxy port on ${COORD_SSH_HOST}" >&2
    return 1
}

echo ">>> PD router: waiting for P/D nodes (job_id=${JOB_ID})..."
python3 "${SCRIPT_DIR}/pd_router.py" wait-pd-ready \
    --job-id "$JOB_ID" --topology "$TOPOLOGY" --timeout "$ROUTER_TIMEOUT"

# Fail fast if registered P/D counts do not match topology (avoid launching half cluster)
python3 - "$JOB_ID" "$TOPOLOGY" "${SCRIPT_DIR}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[3])
from pd_router import load_entries, endpoints_by_role, count_expected_pd_roles, DEFAULT_CONFIG
job_id, topology = sys.argv[1], sys.argv[2]
n_p, n_d = count_expected_pd_roles(topology)
entries = load_entries(DEFAULT_CONFIG, job_id)
p_cnt = len(endpoints_by_role(entries, "prefill"))
d_cnt = len(endpoints_by_role(entries, "decode"))
print(f"registered prefill={p_cnt} decode={d_cnt} (expect {n_p}P{n_d}D)")
if p_cnt != n_p or d_cnt != n_d:
    print(
        f"ERROR: incomplete PD registration for {topology}: "
        f"got P={p_cnt} D={d_cnt}, need P={n_p} D={n_d}",
        file=sys.stderr,
    )
    sys.exit(1)
PY

PORT_SEED=$(printf '%s' "${JOB_ID}" | cksum | awk '{print $1}')
PROXY_PORT=$(pick_free_port "$PORT_SEED")
TAG=$(resolve_image_tag "$VERSION")
CONTAINER="pd_router_${TEST_TYPE}Test_${SESSION_ID}_${JOB_COUNT}"
LOG_NAME="/home/s_limingge/pd_router_${TEST_TYPE}_${SESSION_ID}_${JOB_COUNT}.log"
LAUNCHER="/home/s_limingge/pd_router_launch_${SESSION_ID}_${JOB_COUNT}.sh"

ssh -q -o ConnectionAttempts=3 "s_limingge@${COORD_SSH_HOST}" \
    "docker rm -f ${CONTAINER} 2>/dev/null || true; rm -f ${LAUNCHER}"

if [ "$ENGINE" = "SGLang" ]; then
    IMAGE="quay.io/ascend/sglang:${TAG}"
    LB_JSON="/tmp/pd_lb_cmd_${SESSION_ID}_${JOB_COUNT}.json"
    python3 "${SCRIPT_DIR}/pd_router.py" sglang-lb-cmd \
        --job-id "$JOB_ID" --host "0.0.0.0" --port "$PROXY_PORT" > "$LB_JSON"
    scp -q "$LB_JSON" "s_limingge@${COORD_SSH_HOST}:/home/s_limingge/pd_lb_cmd_${SESSION_ID}_${JOB_COUNT}.json"
    cat > "/tmp/pd_router_launch_${SESSION_ID}_${JOB_COUNT}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
docker pull ${IMAGE} || true
docker run -d --name=${CONTAINER} --network host --ipc=host \\
  -v /home/s_limingge:/home/s_limingge \\
  ${IMAGE} bash -lc 'python3 -c "import json,subprocess; cmd=json.load(open(\"/home/s_limingge/pd_lb_cmd_${SESSION_ID}_${JOB_COUNT}.json\"))[\"cmd\"]; subprocess.check_call(cmd)" > ${LOG_NAME} 2>&1'
EOF
elif [ "$ENGINE" = "vLLM" ]; then
    IMAGE="quay.io/ascend/vllm-ascend:${TAG}"
    PROXY_JSON="/tmp/pd_vllm_proxy_${SESSION_ID}_${JOB_COUNT}.json"
    # Dump endpoints JSON to a file — never eval JSON in bash
    python3 - "$SCRIPT_DIR" "$JOB_ID" "$PROXY_JSON" <<'PY'
import json, re, subprocess, sys
script_dir, job_id, out_path = sys.argv[1:4]
proc = subprocess.run(
    [sys.executable, f"{script_dir}/pd_router.py", "print-endpoints",
     "--job-id", job_id, "--engine", "vllm"],
    check=True, capture_output=True, text=True,
)
m = re.search(r"^VLLM_PROXY=(.*)$", proc.stdout, re.M)
if not m:
    sys.stderr.write(proc.stdout)
    raise SystemExit("ERROR: VLLM_PROXY missing from print-endpoints")
raw = m.group(1).strip()
if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
    import ast
    raw = ast.literal_eval(raw)
payload = json.loads(raw)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
print("vLLM proxy endpoints:", json.dumps(payload, ensure_ascii=False))
if not payload.get("prefiller_hosts") or not payload.get("decoder_hosts"):
    raise SystemExit("ERROR: empty prefiller/decoder endpoints")
PY
    scp -q "$PROXY_JSON" "s_limingge@${COORD_SSH_HOST}:/home/s_limingge/pd_vllm_proxy_${SESSION_ID}_${JOB_COUNT}.json"
    cat > "/tmp/pd_router_launch_${SESSION_ID}_${JOB_COUNT}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IMAGE="${IMAGE}"
CONTAINER="${CONTAINER}"
LOG_NAME="${LOG_NAME}"
PROXY_PORT="${PROXY_PORT}"
PROXY_JSON="/home/s_limingge/pd_vllm_proxy_${SESSION_ID}_${JOB_COUNT}.json"
docker pull "\${IMAGE}" || true
SCRIPT=\$(docker run --rm "\${IMAGE}" bash -lc 'find / -name load_balance_proxy_server_example.py 2>/dev/null | head -n1')
if [ -z "\${SCRIPT}" ]; then
  echo "ERROR: load_balance_proxy_server_example.py not found in image" >&2
  exit 1
fi
PH=\$(python3 -c "import json; d=json.load(open('\${PROXY_JSON}')); print(' '.join(d['prefiller_hosts']))")
PP=\$(python3 -c "import json; d=json.load(open('\${PROXY_JSON}')); print(' '.join(str(x) for x in d['prefiller_ports']))")
DH=\$(python3 -c "import json; d=json.load(open('\${PROXY_JSON}')); print(' '.join(d['decoder_hosts']))")
DP=\$(python3 -c "import json; d=json.load(open('\${PROXY_JSON}')); print(' '.join(str(x) for x in d['decoder_ports']))")
echo ">>> vLLM proxy args: prefiller-hosts=\${PH} prefiller-ports=\${PP} decoder-hosts=\${DH} decoder-ports=\${DP}"
docker run -d --name="\${CONTAINER}" --network host --ipc=host \\
  -v /home/s_limingge:/home/s_limingge \\
  "\${IMAGE}" bash -lc "python3 \${SCRIPT} --host 0.0.0.0 --port \${PROXY_PORT} --prefiller-hosts \${PH} --prefiller-ports \${PP} --decoder-hosts \${DH} --decoder-ports \${DP} > \${LOG_NAME} 2>&1"
EOF
else
    echo "ERROR: unsupported ENGINE for PD router: $ENGINE" >&2
    exit 1
fi

chmod +x "/tmp/pd_router_launch_${SESSION_ID}_${JOB_COUNT}.sh"
scp -q "/tmp/pd_router_launch_${SESSION_ID}_${JOB_COUNT}.sh" \
    "s_limingge@${COORD_SSH_HOST}:${LAUNCHER}"
ssh -q -o ConnectionAttempts=3 "s_limingge@${COORD_SSH_HOST}" "bash ${LAUNCHER}"

echo ">>> PD router: waiting for HTTP on ${COORD_LOCAL_IP}:${PROXY_PORT}..."
deadline=$(( $(date +%s) + ROUTER_TIMEOUT ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -sf --max-time 3 "http://${COORD_LOCAL_IP}:${PROXY_PORT}/v1/models" >/dev/null 2>&1 \
        || curl -sf --max-time 3 "http://${COORD_LOCAL_IP}:${PROXY_PORT}/health" >/dev/null 2>&1 \
        || curl -sf --max-time 3 "http://${COORD_LOCAL_IP}:${PROXY_PORT}/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 3
done
if [ "$ready" -ne 1 ]; then
    echo "WARN: proxy HTTP probe timed out; check ${LOG_NAME} on ${COORD_SSH_HOST}"
fi

ENGINE_KEY=$(echo "$ENGINE" | tr '[:upper:]' '[:lower:]')
python3 "${SCRIPT_DIR}/pd_router.py" register-proxy \
    --job-id "$JOB_ID" \
    --ip "$COORD_LOCAL_IP" \
    --port "$PROXY_PORT" \
    --topology "$TOPOLOGY" \
    --engine "$ENGINE_KEY"

echo ">>> PD router ready: http://${COORD_LOCAL_IP}:${PROXY_PORT}"
