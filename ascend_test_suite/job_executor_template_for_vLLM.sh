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
LOCAL_IP=$(hostname -I | xargs printf "%s\n" | grep "10.0.0" | head -n 1)
SERVER_NAME=$(echo $LOCAL_IP | sed 's/\./_/g')

# PD 分离（可选）：PD_TOPOLOGY=2P2D PD_ROLE=prefill|decode|proxy
# 每个 P/D 节点本地分配端口并写入 server_config；协调节点在引擎就绪后 sync Prometheus。
# scrape IP 使用 server_config 中的地址（通常为 10.0.0.x），Prometheus 需能访问。
PD_TOPOLOGY="${PD_TOPOLOGY:-}"
PD_ROLE="${PD_ROLE:-}"
PD_ENGINE="${PD_ENGINE:-vllm}"
PD_INSTANCE_ID="${PD_INSTANCE_ID:-}"
PD_CONTAINER_SUFFIX=""
if [ -n "$PD_INSTANCE_ID" ]; then
    PD_CONTAINER_SUFFIX="_${PD_INSTANCE_ID}"
fi
# Excel 保持合部命令；PD 角色参数由此注入（可用 PD_VLLM_KV_CONNECTOR 覆盖）
# Ascend 910B：默认 MooncakeConnector（NixlConnector 为 NVIDIA 向）
# kv_port / engine_id 在分配端口后写入，避免默认 14579 或多实例冲突
PD_VLLM_KV_CONNECTOR="${PD_VLLM_KV_CONNECTOR:-MooncakeConnector}"
PD_EXTRA_ARGS=""
PD_KV_ROLE=""
if [ -n "$PD_TOPOLOGY" ]; then
    case "$PD_ROLE" in
        prefill)
            PD_KV_ROLE="kv_producer"
            ;;
        decode)
            PD_KV_ROLE="kv_consumer"
            ;;
        proxy)
            PD_KV_ROLE=""
            ;;
        *)
            echo "ERROR: unsupported PD_ROLE=$PD_ROLE (need prefill|decode|proxy)"
            exit 1
            ;;
    esac
fi

# 设置清理函数，确保异常退出时释放锁
cleanup_locks() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "中止job executor测试任务......"
        if [ ! -z "$LOCKED_NPUS" ]; then
            echo "检测到异常退出（退出码: $exit_code），正在释放Server Config文件锁: ${LOCK_DIR}/${LOCK_FILE}"
            # 获取文件锁（阻塞）
            exec 200>"${LOCK_DIR}/${LOCK_FILE}"    # 打开文件描述符 200
            if ! flock -x 200; then    # 获取独占锁
                echo "无法获取锁，退出..."
            fi
            # 删除Server端配置信息，如果存在的话
            # sed -i "/${LOCAL_IP}:${JOB_ID}:/d" "${LOCK_DIR}/server_config.txt"
            new_config=`sed "/${LOCAL_IP}:${JOB_ID}:/d" "${LOCK_DIR}/server_config.txt"`
            echo "${new_config}" > "${LOCK_DIR}/server_config.txt"
            # 锁会自动在脚本退出或文件描述符关闭时释放
            exec 200>&-  # 关闭文件描述符
            echo "正在释放NPU锁: ${LOCKED_NPUS}"
            release_npu_locks_batch "$SERVER_NAME" "$LOCKED_NPUS" "$TASK_ID" "$SESSION_ID"
        fi
    else
        echo "正常退出（退出码: 0），保留NPU锁"
    fi
}

# 注册退出时的清理函数
trap cleanup_locks EXIT INT TERM

free_port=""
server_ports=()
# Mooncake handshake 会占用 kv_port .. kv_port+tp_size-1，预留一块避免同机冲突
KV_PORT_BLOCK_SIZE="${PD_VLLM_KV_PORT_BLOCK:-32}"

# 从 server_config 收集本机已登记端口（含 bootstrap_port=N / kv_port=N 及 Mooncake 端口块）
collect_reserved_ports() {
    local ip="$1"
    server_ports=()
    [ -f "${LOCK_DIR}/server_config.txt" ] || return 0
    local line rest tok base i
    while IFS= read -r line; do
        rest="${line#*:*:}"
        for tok in $rest; do
            if [[ "$tok" =~ ^[0-9]+$ ]]; then
                server_ports+=("$tok")
            elif [[ "$tok" =~ ^kv_port=([0-9]+)$ ]]; then
                base="${BASH_REMATCH[1]}"
                for ((i = 0; i < KV_PORT_BLOCK_SIZE; i++)); do
                    server_ports+=("$((base + i))")
                done
            elif [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*=([0-9]+)$ ]]; then
                server_ports+=("${BASH_REMATCH[1]}")
            fi
        done
    done < <(grep -E "^${ip}:" "${LOCK_DIR}/server_config.txt" 2>/dev/null || true)
}

port_is_busy() {
    local port="$1"
    if [[ " ${server_ports[*]} " == *" ${port} "* ]]; then
        return 0
    fi
    if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
        return 0
    fi
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
        return 0
    fi
    if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        return 0
    fi
    if (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

get_free_port() {
    local PORT_RANGE_START=20000
    local PORT_RANGE_END=20999
    local port

    for port in $(seq $PORT_RANGE_START $PORT_RANGE_END); do
        if port_is_busy "$port"; then
            continue
        fi
        server_ports+=("$port")
        free_port="$port"
        return
    done
    free_port=""
}

# 连续 block 个空闲端口，返回起始口（用于 Mooncake kv_port）
get_free_port_block() {
    local block_size="${1:-32}"
    local PORT_RANGE_START=21000
    local PORT_RANGE_END=22999
    local port i ok
    free_port=""
    for port in $(seq $PORT_RANGE_START $((PORT_RANGE_END - block_size + 1))); do
        ok=1
        for ((i = 0; i < block_size; i++)); do
            if port_is_busy "$((port + i))"; then
                ok=0
                break
            fi
        done
        if [ "$ok" -eq 1 ]; then
            for ((i = 0; i < block_size; i++)); do
                server_ports+=("$((port + i))")
            done
            free_port="$port"
            return
        fi
    done
}

if [ $USE_PREFIX_CACHE -eq 1 ]; then
    USE_PREFIX_CACHE="--use-prefix-cache"
else
    USE_PREFIX_CACHE=""
fi

SWAP_SPACE_OPTION=""
if [ $SWAP_SPACE -gt 0 ]; then
    SWAP_SPACE_OPTION="--swap-space $SWAP_SPACE"
fi

LATEST_TAG=""
if [ -z $VERSION ]; then
    echo "vLLM version is not specified!"
    exit 1;
else
    LATEST_TAG=$VERSION
    echo "The specified version : $LATEST_TAG"
fi

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

docker_pull_with_retry "quay.io/ascend/vllm-ascend:$LATEST_TAG" || exit 1

ret=`docker ps -a | grep vllm_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX}`
if [ $? -eq 0 ]; then
    docker stop vllm_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX}
    docker rm vllm_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX}
fi

# Slave节点需要等待Master节点的HTTP Server启动完成......
if [ $NODE_RANK -ne 0 ]; then
  sleep 30
fi

# 设置超时时间(单位:秒, 1小时 = 3600秒)
TIMEOUT=10
START_TIME=$(date +%s)

# 目标空闲 GPU 数量
if [ $GPU_QUANITY -eq 16 ]; then
    TARGET_FREE_GPUS=8
else
    TARGET_FREE_GPUS=$GPU_QUANITY
fi

# 检查 npu-smi 命令是否存在
if ! command -v npu-smi &> /dev/null; then
    echo "错误: npu-smi 未找到，请确保 Ascend 910B 驱动已安装"
    exit 1
fi

echo "开始扫描 GPU, 目标: 寻找 $TARGET_FREE_GPUS 张空闲 GPU..."

LOCKED_NPUS=""
while true; do
    # 检查是否超时
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
        echo "超时（${TIMEOUT}秒）未找到 $TARGET_FREE_GPUS 张空闲 GPU, 退出"
        exit 10
    fi

    # 使用 npu-smi 获取 GPU 使用情况
    GPU_INFO=($(npu-smi info | grep "No\ running\ processes\ found\ in\ NPU" | awk '{print $8}'))
    # 检查空闲 GPU 数量
    FREE_COUNT=$(echo "${GPU_INFO[@]}" | wc -w)
    echo "当前空闲 GPU 数量：$FREE_COUNT, 索引: ${GPU_INFO[@]}"
    # 如果找到足够的空闲 GPU, 则返回结果并退出
    if [ "$FREE_COUNT" -ge "$TARGET_FREE_GPUS" ]; then
        echo "发现 $TARGET_FREE_GPUS 张空闲 GPU, 索引: ${GPU_INFO[@]}"
        echo "尝试锁定其中 $TARGET_FREE_GPUS 张 GPU"

        # 尝试原子性地获取所有NPU的锁
        if acquire_npu_locks_batch "$SERVER_NAME" "${GPU_INFO[*]}" "$TARGET_FREE_GPUS" "$TASK_ID" "$SESSION_ID" ACUQIRED_LOCKS; then
            echo "成功锁定 $TARGET_FREE_GPUS 张 GPU, 索引：${ACUQIRED_LOCKS[@]}"
            LOCKED_NPUS="${ACUQIRED_LOCKS[@]}"
            GPU_INFO=(${ACUQIRED_LOCKS[@]})
            break
        else
            echo "锁定失败（可能被其他任务占用），继续扫描......"
        fi
    fi

    # 等待一段时间后重新扫描（例如 10 秒）
    echo "未找到足够的空闲 GPU, 10秒后重试......"
    sleep 10
done

ASCEND_RT_VISIBLE_DEVICES=$(echo "${GPU_INFO[@]}" | sed -E 's/\s+/\,/g')
echo "ASCEND_RT_VISIBLE_DEVICES=$ASCEND_RT_VISIBLE_DEVICES"

LOG_NAME="server_log_<<<TEST_TYPE>>>_$(date +'%Y%m%d_%H%M%S').log"

MASTER_IP=`echo $SERVER_LIST | tr '_' '\n' | head -n 1`

allocate_and_write_local_ports() {
    local extra_kv="$1"
    # 获取文件锁（阻塞）
    exec 200>"${LOCK_DIR}/${LOCK_FILE}"
    if ! flock -x 200; then
        echo "无法获取锁，退出..."
        exit 1
    fi

    if [ ! -f "${LOCK_DIR}/server_config.txt" ]; then
        touch "${LOCK_DIR}/server_config.txt"
    fi

    collect_reserved_ports "$LOCAL_IP"

    get_free_port
    PORT=$free_port
    get_free_port
    PROMETHEUS_PORT=$free_port
    get_free_port
    MASTER_PORT=$free_port
    KV_PORT=""

    # PD + Mooncake：每实例独立 kv_port（及后续 TP handshake 端口块）
    if [ -n "$PD_TOPOLOGY" ] && [ -n "$PD_KV_ROLE" ]; then
        get_free_port_block "$KV_PORT_BLOCK_SIZE"
        KV_PORT=$free_port
        if [ -z "$KV_PORT" ]; then
            exec 200>&-
            echo "ERROR: failed to allocate Mooncake kv_port block"
            exit 1
        fi
        local engine_id="${PD_INSTANCE_ID:-${PD_ROLE}}"
        PD_EXTRA_ARGS="--kv-transfer-config '{\"kv_connector\":\"${PD_VLLM_KV_CONNECTOR}\",\"kv_role\":\"${PD_KV_ROLE}\",\"kv_port\":${KV_PORT},\"engine_id\":\"${engine_id}\"}'"
        if [ -n "$extra_kv" ]; then
            extra_kv="${extra_kv} kv_port=${KV_PORT}"
        else
            extra_kv="kv_port=${KV_PORT}"
        fi
        echo "PD Mooncake: kv_port=${KV_PORT} (block=${KV_PORT_BLOCK_SIZE}) role=${PD_KV_ROLE} engine_id=${engine_id}"
        echo "PD extra args: $PD_EXTRA_ARGS"
    fi

    if [ -z "$PORT" ] || [ -z "$PROMETHEUS_PORT" ] || [ -z "$MASTER_PORT" ]; then
        exec 200>&-
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
    # PD：每个 Prefill/Decode 节点各自分配端口并写入本机一行（含 role/topology/engine）
    if [ -z "$PD_ROLE" ]; then
        echo "ERROR: PD_TOPOLOGY is set but PD_ROLE is empty (need prefill|decode|proxy)"
        exit 1
    fi
    echo "PD mode: topology=$PD_TOPOLOGY role=$PD_ROLE engine=$PD_ENGINE"
    allocate_and_write_local_ports "role=$PD_ROLE topology=$PD_TOPOLOGY engine=$PD_ENGINE"
elif [ $LOCAL_IP == $MASTER_IP ]; then        # 获取Master节点的端口号
    allocate_and_write_local_ports ""
else    # Slave节点同步到master节点的端口配置
    while true; do
        # 获取文件锁（阻塞）
        exec 200>"${LOCK_DIR}/${LOCK_FILE}"    # 打开文件描述符 200
        if ! flock -x 200; then    # 获取独占锁
            echo "无法获取锁，退出..."
            exit 1
        fi

        # 读取Master节点配置信息
        server_ports=`cat "${LOCK_DIR}/server_config.txt" | grep "${MASTER_IP}:${JOB_ID}:" | awk -F ':' '{print $3}' | tail -n 1`
        if [ ! -z "$server_ports" ]; then
            PORT=$(echo $server_ports | awk '{print $1}')
            PROMETHEUS_PORT=$(echo $server_ports | awk '{print $2}')
            MASTER_PORT=$(echo $server_ports | awk '{print $3}')
            # 锁会自动在脚本退出或文件描述符关闭时释放
            exec 200>&-  # 关闭文件描述符
            break
        fi

        # 锁会自动在脚本退出或文件描述符关闭时释放
        exec 200>&-  # 关闭文件描述符

        sleep 1
    done
fi

EXEC_COMMAND="docker run --name=vllm_ascend_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}${PD_CONTAINER_SUFFIX} \
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
  -v /usr/local/Ascend/driver/include:/usr/local/Ascend/driver/include	\
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
  -e ASCEND_RT_VISIBLE_DEVICES=$ASCEND_RT_VISIBLE_DEVICES  \
  quay.io/ascend/vllm-ascend:$LATEST_TAG"

<<<generated source code>>>

echo "$EXEC_COMMAND"

eval "$EXEC_COMMAND"
if [ $? -ne 0 ]; then
    exit 1;
fi

TIMEOUT_SECONDS=$((60*30)) # 设置启动超时时间为30分钟
if [ -n "$PD_TOPOLOGY" ] || [ $NODE_RANK -eq 0 ]; then
    # PD 各角色节点、或非 PD 的 master：等待本节点 HTTP 服务就绪
    timeout $TIMEOUT_SECONDS tail -F $LOG_NAME | grep --line-buffered -m 1 -E "INFO:\s+Application startup complete\."
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
    timeout $TIMEOUT_SECONDS tail -F $LOG_NAME | grep --line-buffered -m 8 -E "worker initialization done!"
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
