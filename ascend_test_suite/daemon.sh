#!/usr/bin/env bash

cleanup() {
    # Ignore further signals: resetting to default would let a second SIGPIPE
    # kill us when we write to the already-broken SSH stdout pipe.
    trap - SIGINT SIGTERM SIGHUP SIGPIPE
    exec >> "${curr_dir}/cleanup.log" 2>&1
    echo "$(date '+%F %T') Stopping CI test job CI_test_job_${CI_job_id}..."
    docker stop --timeout 60 "CI_test_job_${CI_job_id}" || true
    # rm -rf $curr_dir
    exit 130
}

trap cleanup SIGINT SIGTERM SIGHUP SIGPIPE

platform=$1
test_type=$2
engine=$3
model_list=$4
CI_job_id=$5
test_param=$6
version=$7

curr_dir=$(pwd)

# 可选 PD 环境变量传入 auto-test 容器（未设置则忽略）
PD_DOCKER_ENV=()
for _pd_var in \
    PD_TOPOLOGY PD_ALLOW_SAME_ROLE_COLOCATE PD_SGLANG_TRANSFER_BACKEND PD_SGLANG_IB_DEVICE \
    PD_VLLM_KV_CONNECTOR ASCEND_MF_STORE_URL MF_CONFIG_STORE_URL ASCEND_MF_TRANSFER_PROTOCOL \
    PD_PROXY_PORT_START PD_PROXY_PORT_RANGE PD_ROUTER_STARTUP_TIMEOUT \
    PD_PIP_INDEX_URL PD_MEMFABRIC_PIP_SPEC PD_MEMFABRIC_WHL PD_MOONCAKE_PIP_SPEC \
    ENABLE_ASCEND_TRANSFER_WITH_MOONCAKE PD_PIP_BOOTSTRAP; do
    if [ -n "${!_pd_var:-}" ]; then
        PD_DOCKER_ENV+=(-e "${_pd_var}=${!_pd_var}")
    fi
done

docker run --rm --name="CI_test_job_${CI_job_id}" --privileged --network host \
  -v /home/s_limingge/.npu_locks:/home/s_limingge/.npu_locks \
  -v /CI_Workspace:/CI_Workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "${PD_DOCKER_ENV[@]}" \
  auto-test:latest $platform $test_type $engine $model_list $CI_job_id $test_param $version &
CHILD_PID=$!

echo -n "Running"
while kill -0 $CHILD_PID 2>/dev/null; do
    # echo -ne "\r\033[KRunning..."
    echo -n "."
    sleep 1
done

wait $CHILD_PID
EXIT_CODE=$?

# If the docker-run client died (e.g. EPIPE on the broken SSH pipe after a
# cancel/timeout) the container may still be running: treat it as an abort.
# On normal completion the container has already exited and been removed.
if [ "$(docker inspect -f '{{.State.Running}}' "CI_test_job_${CI_job_id}" 2>/dev/null)" = "true" ]; then
    cleanup
fi

# rm -rf $curr_dir

exit $EXIT_CODE
