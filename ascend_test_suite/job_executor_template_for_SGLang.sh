#!/bin/bash

# 导入NPU锁管理器
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/npu_lock_manager_for_ci.sh"
LOCK_DIR="/home/s_limingge/.npu_locks"
LOCK_FILE="server_config.lock"

# 接收参数
MODEL=$1
GPU_QUANITY=$2
USE_PREFIX_CACHE=$3
SCHEDULE_POLICY=$4
SWAP_SPACE=$5
SERVER_LIST=$6
NODE_RANK=$7
JOB_COUNT=$8
SESSION_ID=$9
VERSION=${10}

# 生成唯一的任务ID
TASK_ID="<<<TEST_TYPE>>>_${MODEL}_${JOB_COUNT}"
JOB_ID="<<<TEST_TYPE>>>_${MODEL}_${SESSION_ID}_${JOB_COUNT}"
LOCAL_IP=$(hostname -I | xargs printf "%s\n" | grep "10.0.0")
SERVER_NAME=$(echo $LOCAL_IP | sed 's/\./_/g')

# PD 分离（可选）：PD_TOPOLOGY=2P2D PD_ROLE=prefill|decode|proxy
# 每个 P/D 节点本地分配端口并写入 server_config；协调节点在引擎就绪后 sync Prometheus。
# scrape IP 使用 server_config 中的地址（通常为 10.0.0.x），Prometheus 需能访问。
PD_TOPOLOGY="${PD_TOPOLOGY:-}"
PD_ROLE="${PD_ROLE:-}"
PD_ENGINE="${PD_ENGINE:-sglang}"
PD_INSTANCE_ID="${PD_INSTANCE_ID:-}"
PD_CONTAINER_SUFFIX=""
if [ -n "$PD_INSTANCE_ID" ]; then
    PD_CONTAINER_SUFFIX="_${PD_INSTANCE_ID}"
fi
# Excel 保持合部命令；PD 角色参数由此注入
# Ascend 910B 无 IB：默认 ascend 后端；可用 PD_SGLANG_TRANSFER_BACKEND=mooncake 覆盖
PD_SGLANG_TRANSFER_BACKEND="${PD_SGLANG_TRANSFER_BACKEND:-ascend}"
PD_SGLANG_IB_DEVICE="${PD_SGLANG_IB_DEVICE:-}"
ASCEND_MF_STORE_URL="${ASCEND_MF_STORE_URL:-}"
MF_CONFIG_STORE_URL="${MF_CONFIG_STORE_URL:-}"
# 910B/A2 官方 PD 文档要求 device_rdma（走 HCCN/RoCE，不是主机 IB 网卡名）
ASCEND_MF_TRANSFER_PROTOCOL="${ASCEND_MF_TRANSFER_PROTOCOL:-device_rdma}"
# Prefill bootstrap HTTP 端口（与 API 端口分离；注册 /route 用这个，不是 Uvicorn API）
PD_BOOTSTRAP_PORT="${PD_BOOTSTRAP_PORT:-}"
# 每次 CI 拉最新镜像，PD 依赖需在容器内动态安装（可用环境变量覆盖）
PD_PIP_INDEX_URL="${PD_PIP_INDEX_URL:-https://pypi.org/simple}"
PD_MEMFABRIC_PIP_SPEC="${PD_MEMFABRIC_PIP_SPEC:-memfabric-hybrid>=1.0.8}"
PD_MEMFABRIC_WHL="${PD_MEMFABRIC_WHL:-}"
PD_MOONCAKE_PIP_SPEC="${PD_MOONCAKE_PIP_SPEC:-mooncake-transfer-engine}"
DOCKER_PD_ENVS=""
PD_DOCKER_CMD_PREFIX=""
PD_DOCKER_CMD_SUFFIX=""
PD_PIP_BOOTSTRAP=""
PD_EXTRA_ARGS=""
if [ -n "$PD_TOPOLOGY" ]; then
    case "$PD_ROLE" in
        prefill)
            PD_EXTRA_ARGS="--disaggregation-mode prefill --disaggregation-transfer-backend ${PD_SGLANG_TRANSFER_BACKEND}"
            ;;
        decode)
            PD_EXTRA_ARGS="--disaggregation-mode decode --disaggregation-transfer-backend ${PD_SGLANG_TRANSFER_BACKEND}"
            ;;
        proxy)
            PD_EXTRA_ARGS=""
            ;;
        *)
            echo "ERROR: unsupported PD_ROLE=$PD_ROLE (need prefill|decode|proxy)"
            exit 1
            ;;
    esac
    if [ -n "$PD_SGLANG_IB_DEVICE" ] && [ "$PD_ROLE" != "proxy" ]; then
        PD_EXTRA_ARGS="${PD_EXTRA_ARGS} --disaggregation-ib-device ${PD_SGLANG_IB_DEVICE}"
    fi
    # ascend 后端：Config Store 地址（所有 P/D 必须一致；优先由协调节点注入）
    if [ "$PD_SGLANG_TRANSFER_BACKEND" = "ascend" ] && [ "$PD_ROLE" != "proxy" ]; then
        if [ -z "$ASCEND_MF_STORE_URL" ]; then
            MF_PORT=$((24669 + $(printf '%s' "$JOB_ID" | cksum | awk '{print $1 % 2000}')))
            ASCEND_MF_STORE_URL="tcp://${LOCAL_IP}:${MF_PORT}"
            echo "WARN: ASCEND_MF_STORE_URL unset; fallback to local $ASCEND_MF_STORE_URL (prefer coordinator injection)"
        fi
        MF_CONFIG_STORE_URL="${MF_CONFIG_STORE_URL:-$ASCEND_MF_STORE_URL}"
        DOCKER_PD_ENVS="${DOCKER_PD_ENVS} -e ASCEND_MF_STORE_URL=${ASCEND_MF_STORE_URL} -e MF_CONFIG_STORE_URL=${MF_CONFIG_STORE_URL}"
        DOCKER_PD_ENVS="${DOCKER_PD_ENVS} -e ASCEND_MF_TRANSFER_PROTOCOL=${ASCEND_MF_TRANSFER_PROTOCOL}"
        # Ascend TransferEngine / bootstrap 用 get_local_ip_auto()；多网卡时必须强制数据面 IP，
        # 否则可能广播 10.9.1.x，对端 WaitingForInput 直至 300s 超时。
        DOCKER_PD_ENVS="${DOCKER_PD_ENVS} -e SGLANG_HOST_IP=${LOCAL_IP}"
        echo "PD memfabric store: $ASCEND_MF_STORE_URL protocol=$ASCEND_MF_TRANSFER_PROTOCOL host_ip=$LOCAL_IP"
        # 容器内动态安装 memfabric（镜像每次更新，不能预装在宿主机）
        if [ -n "$PD_MEMFABRIC_WHL" ]; then
            PD_PIP_BOOTSTRAP="${PD_PIP_BOOTSTRAP} python3 -c 'import memfabric_hybrid' 2>/dev/null || pip3 install --no-cache-dir '${PD_MEMFABRIC_WHL}' || exit 1; "
        else
            PD_PIP_BOOTSTRAP="${PD_PIP_BOOTSTRAP} python3 -c 'import memfabric_hybrid' 2>/dev/null || pip3 install --no-cache-dir '${PD_MEMFABRIC_PIP_SPEC}' -i '${PD_PIP_INDEX_URL}' || exit 1; "
        fi
    fi
    # mooncake 在 Ascend 上需打开适配开关（无 IB 时走 TCP），并按需动态安装
    if [ "$PD_SGLANG_TRANSFER_BACKEND" = "mooncake" ] && [ "$PD_ROLE" != "proxy" ]; then
        DOCKER_PD_ENVS="${DOCKER_PD_ENVS} -e ENABLE_ASCEND_TRANSFER_WITH_MOONCAKE=true"
        PD_PIP_BOOTSTRAP="${PD_PIP_BOOTSTRAP} python3 -c 'import mooncake' 2>/dev/null || pip3 install --no-cache-dir '${PD_MOONCAKE_PIP_SPEC}' -i '${PD_PIP_INDEX_URL}' || exit 1; "
    fi
    if [ -n "$PD_PIP_BOOTSTRAP" ]; then
        # docker run IMAGE bash -lc "pip...; launch_server ..."
        # 注意：外层用双引号，包名用已展开后的单引号，避免嵌套引号打断
        PD_DOCKER_CMD_PREFIX="bash -lc \"${PD_PIP_BOOTSTRAP}"
        PD_DOCKER_CMD_SUFFIX="\""
        echo "PD container bootstrap: dynamic pip install enabled ($PD_SGLANG_TRANSFER_BACKEND)"
    fi
    echo "PD extra args: $PD_EXTRA_ARGS"
fi

# 设置清理函数，确保异常退出时释放锁
cleanup_locks() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "中止job executor测试任务......"
        if [ ! -z "$LOCKED_NPUS" ]; then
            echo "检测到异常退出（退出码: $exit_code），正在释放Server Config文件锁: ${LOCK_DIR}/${LOCK_FILE}"
            exec 200>"${LOCK_DIR}/${LOCK_FILE}"
            if ! flock -x 200; then
                echo "无法获取锁，退出..."
            fi
            new_config=`sed "/${LOCAL_IP}:${JOB_ID}:/d" "${LOCK_DIR}/server_config.txt"`
            echo "${new_config}" > "${LOCK_DIR}/server_config.txt"
            exec 200>&-
            echo "正在释放NPU锁: ${LOCKED_NPUS}"
            release_npu_locks_batch "$SERVER_NAME" "$LOCKED_NPUS" "$TASK_ID" "$SESSION_ID"
        fi
    else
        echo "正常退出（退出码: 0），保留NPU锁"
    fi
}

trap cleanup_locks EXIT INT TERM

free_port=""

get_free_port() {
    local PORT_RANGE_START=20000
    local PORT_RANGE_END=20999

    for port in $(seq $PORT_RANGE_START $PORT_RANGE_END); do
        if ! lsof -i :"$port" >/dev/null 2>&1; then
            if [[ " ${server_ports[@]} " =~ " $port " ]]; then
                continue
            fi
            server_ports+=($port)
            free_port="$port"
            return
        fi
    done
    free_port=""
}

if [ $USE_PREFIX_CACHE -eq 1 ]; then
    SGLANG_PREFIX_CACHE=""
else
    SGLANG_PREFIX_CACHE="--disable-radix-cache"
fi

IMAGE_REPO="quay.io/ascend/sglang"
# 910B 默认后缀；可用环境变量覆盖，例如 SGLANG_NPU_TAG_SUFFIX=cann9.0.0-a3
SGLANG_NPU_TAG_SUFFIX="${SGLANG_NPU_TAG_SUFFIX:-cann9.0.0-910b}"
LATEST_TAG=""
if [ -z "$VERSION" ]; then
    echo "SGLang version is not specified!"
    exit 1;
elif [[ "$VERSION" == *cann* || "$VERSION" == *910b* || "$VERSION" == *a3* ]]; then
    LATEST_TAG="$VERSION"
else
    LATEST_TAG="${VERSION}-${SGLANG_NPU_TAG_SUFFIX}"
fi
echo "The specified version : $VERSION -> image tag : $LATEST_TAG"

# quay.io 等外网 registry 偶发 TLS timeout，拉取失败时重试
docker_pull_with_retry() {
    local image="$1"
    local max_retries="${DOCKER_PULL_MAX_RETRIES:-5}"
    local delay="${DOCKER_PULL_RETRY_DELAY:-30}"
    local attempt=1
    while [ "$attempt" -le "$max_retries" ]; do
        echo "docker pull ${image} (attempt ${attempt}/${max_retries})"
        if docker pull "${image}"; then
            echo "docker pull succeeded: ${image}"
            return 0
        fi
        if [ "$attempt" -ge "$max_retries" ]; then
            echo "ERROR: docker pull failed after ${max_retries} attempts: ${image}"
            return 1
        fi
        echo "docker pull failed, retry in ${delay}s..."
        sleep "${delay}"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
        if [ "$delay" -gt 300 ]; then
            delay=300
        fi
    done
    return 1
}

docker_pull_with_retry "${IMAGE_REPO}:$LATEST_TAG" || exit 1

ret=`docker ps -a | grep sglang_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX}`
if [ $? -eq 0 ]; then
    docker stop sglang_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX}
    docker rm sglang_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX}
fi

if [ $NODE_RANK -ne 0 ]; then
  sleep 30
fi

TIMEOUT=10
START_TIME=$(date +%s)

if [ $GPU_QUANITY -eq 16 ]; then
    TARGET_FREE_GPUS=8
else
    TARGET_FREE_GPUS=$GPU_QUANITY
fi

if ! command -v npu-smi &> /dev/null; then
    echo "错误: npu-smi 未找到，请确保 Ascend 910B 驱动已安装"
    exit 1
fi

echo "开始扫描 GPU, 目标: 寻找 $TARGET_FREE_GPUS 张空闲 GPU..."

LOCKED_NPUS=""
while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
        echo "超时（${TIMEOUT}秒）未找到 $TARGET_FREE_GPUS 张空闲 GPU, 退出"
        exit 10
    fi

    GPU_INFO=($(npu-smi info | grep "No\ running\ processes\ found\ in\ NPU" | awk '{print $8}'))
    FREE_COUNT=$(echo "${GPU_INFO[@]}" | wc -w)
    echo "当前空闲 GPU 数量：$FREE_COUNT, 索引: ${GPU_INFO[@]}"
    if [ "$FREE_COUNT" -ge "$TARGET_FREE_GPUS" ]; then
        echo "发现 $TARGET_FREE_GPUS 张空闲 GPU, 索引: ${GPU_INFO[@]}"
        echo "尝试锁定其中 $TARGET_FREE_GPUS 张 GPU"

        if acquire_npu_locks_batch "$SERVER_NAME" "${GPU_INFO[*]}" "$TARGET_FREE_GPUS" "$TASK_ID" "$SESSION_ID" ACUQIRED_LOCKS; then
            echo "成功锁定 $TARGET_FREE_GPUS 张 GPU, 索引：${ACUQIRED_LOCKS[@]}"
            LOCKED_NPUS="${ACUQIRED_LOCKS[@]}"
            GPU_INFO=(${ACUQIRED_LOCKS[@]})
            break
        else
            echo "锁定失败（可能被其他任务占用），继续扫描......"
        fi
    fi

    echo "未找到足够的空闲 GPU, 10秒后重试......"
    sleep 10
done

ASCEND_RT_VISIBLE_DEVICES=$(echo "${GPU_INFO[@]}" | sed -E 's/\s+/\,/g')
echo "ASCEND_RT_VISIBLE_DEVICES=$ASCEND_RT_VISIBLE_DEVICES"

LOG_NAME="server_log_<<<TEST_TYPE>>>_$(date +'%Y%m%d_%H%M%S').log"

MASTER_IP=`echo $SERVER_LIST | tr '_' '\n' | head -n 1`

allocate_and_write_local_ports() {
    local extra_kv="$1"
    exec 200>"${LOCK_DIR}/${LOCK_FILE}"
    if ! flock -x 200; then
        echo "无法获取锁，退出..."
        exit 1
    fi

    if [ ! -f "${LOCK_DIR}/server_config.txt" ]; then
        touch "${LOCK_DIR}/server_config.txt"
    fi

    server_ports=(`cat "${LOCK_DIR}/server_config.txt" | grep $LOCAL_IP | awk -F ':' '{print $3}'`)

    get_free_port
    PORT=$free_port
    get_free_port
    PROMETHEUS_PORT=$free_port
    get_free_port
    MASTER_PORT=$free_port
    BOOTSTRAP_PORT=""
    if [ -n "$PD_TOPOLOGY" ] && [ "$PD_ROLE" = "prefill" ]; then
        get_free_port
        BOOTSTRAP_PORT=$free_port
        PD_EXTRA_ARGS="${PD_EXTRA_ARGS} --disaggregation-bootstrap-port ${BOOTSTRAP_PORT}"
        if [ -n "$extra_kv" ]; then
            extra_kv="${extra_kv} bootstrap_port=${BOOTSTRAP_PORT}"
        else
            extra_kv="bootstrap_port=${BOOTSTRAP_PORT}"
        fi
        echo "PD prefill bootstrap_port=$BOOTSTRAP_PORT (API port=$PORT)"
    fi

    if [ -z $PORT ] || [ -z $PROMETHEUS_PORT ] || [ -z $MASTER_PORT ]; then
        exec 200>&-
        exit 1
    fi
    if [ "$PD_ROLE" = "prefill" ] && [ -z "$BOOTSTRAP_PORT" ]; then
        exec 200>&-
        echo "ERROR: failed to allocate disaggregation bootstrap port"
        exit 1
    fi

    if [ -n "$extra_kv" ]; then
        echo "$LOCAL_IP:$JOB_ID:$PORT $PROMETHEUS_PORT $MASTER_PORT $extra_kv" >> "${LOCK_DIR}/server_config.txt"
    else
        echo "$LOCAL_IP:$JOB_ID:$PORT $PROMETHEUS_PORT $MASTER_PORT" >> "${LOCK_DIR}/server_config.txt"
    fi
    exec 200>&-
}

if [ -n "$PD_TOPOLOGY" ]; then
    if [ -z "$PD_ROLE" ]; then
        echo "ERROR: PD_TOPOLOGY is set but PD_ROLE is empty (need prefill|decode|proxy)"
        exit 1
    fi
    echo "PD mode: topology=$PD_TOPOLOGY role=$PD_ROLE engine=$PD_ENGINE"
    allocate_and_write_local_ports "role=$PD_ROLE topology=$PD_TOPOLOGY engine=$PD_ENGINE"
    echo "PD extra args (final): $PD_EXTRA_ARGS"
elif [ $LOCAL_IP == $MASTER_IP ]; then
    allocate_and_write_local_ports ""
else
    while true; do
        exec 200>"${LOCK_DIR}/${LOCK_FILE}"
        if ! flock -x 200; then
            echo "无法获取锁，退出..."
            exit 1
        fi

        server_ports=`cat "${LOCK_DIR}/server_config.txt" | grep "${MASTER_IP}:${JOB_ID}:" | awk -F ':' '{print $3}' | tail -n 1`
        if [ ! -z "$server_ports" ]; then
            PORT=$(echo $server_ports | awk '{print $1}')
            PROMETHEUS_PORT=$(echo $server_ports | awk '{print $2}')
            MASTER_PORT=$(echo $server_ports | awk '{print $3}')
            exec 200>&-
            break
        fi

        exec 200>&-
        sleep 1
    done
fi

EXEC_COMMAND="docker run --name=sglang_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX} \
  --network host \
  --ipc=host \
  --privileged \
  --shm-size=10995116277 \
  --workdir /workspace \
  -v /dev/davinci0:/dev/davinci0 \
  -v /dev/davinci1:/dev/davinci1 \
  -v /dev/davinci2:/dev/davinci2 \
  -v /dev/davinci3:/dev/davinci3 \
  -v /dev/davinci4:/dev/davinci4 \
  -v /dev/davinci5:/dev/davinci5 \
  -v /dev/davinci6:/dev/davinci6 \
  -v /dev/davinci7:/dev/davinci7 \
  --device /dev/davinci_manager:/dev/davinci_manager \
  --device /dev/devmm_svm:/dev/devmm_svm \
  --device /dev/hisi_hdc:/dev/hisi_hdc \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/include:/usr/local/Ascend/driver/include \
  -v /usr/local/Ascend/driver/tools:/usr/local/Ascend/driver/tools  \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -v /usr/bin/hccn_tool:/usr/bin/hccn_tool \
  -v /root/.cache:/root/.cache \
  -v /data:/data \
  -v /home/weight:/home/weight \
  -v /home/s_limingge:/home/s_limingge \
  -e HCCL_SOCKET_IFNAME=enp67s0f0 \
  -e ASCEND_RT_VISIBLE_DEVICES=$ASCEND_RT_VISIBLE_DEVICES \
  ${DOCKER_PD_ENVS} \
  ${IMAGE_REPO}:$LATEST_TAG"

<<<generated source code>>>

# PD：API/bootstrap 绑定数据面 IP（与官方 Ascend 示例一致；勿用 0.0.0.0 作为对外通告地址）
if [ -n "$PD_TOPOLOGY" ] && [ "$PD_ROLE" != "proxy" ]; then
    EXEC_COMMAND="${EXEC_COMMAND//--host 0.0.0.0/--host ${LOCAL_IP}}"
    echo "PD bind host overridden to data-plane LOCAL_IP=$LOCAL_IP"
fi

echo "$EXEC_COMMAND"

eval "$EXEC_COMMAND"
if [ $? -ne 0 ]; then
    exit 1;
fi

TIMEOUT_SECONDS=$((60*30))
if [ -n "$PD_TOPOLOGY" ] || [ $NODE_RANK -eq 0 ]; then
    timeout $TIMEOUT_SECONDS tail -F $LOG_NAME | grep --line-buffered -m 1 -E "The server is fired up and ready to roll|Application startup complete"
    EXIT_STATUS=$?
    if [ $EXIT_STATUS -eq 124 ]; then
        echo "模型启动超时（${TIMEOUT_SECONDS}秒）"
    elif [ $EXIT_STATUS -eq 0 ]; then
        echo ">>> Detected master/PD service startup completion!"
    else
        echo "模型启动失败，退出状态码：$EXIT_STATUS"
    fi

    exit $EXIT_STATUS
else
    timeout $TIMEOUT_SECONDS tail -F $LOG_NAME | grep --line-buffered -m 8 -E "The server is fired up and ready to roll|Init torch distributed"
    EXIT_STATUS=$?
    if [ $EXIT_STATUS -eq 124 ]; then
        echo "模型启动超时（${TIMEOUT_SECONDS}秒）"
    elif [ $EXIT_STATUS -eq 0 ]; then
        echo ">>> Detected worker service startup completion!"
    else
        echo "模型启动失败，退出状态码：$EXIT_STATUS"
    fi

    exit $EXIT_STATUS
fi
