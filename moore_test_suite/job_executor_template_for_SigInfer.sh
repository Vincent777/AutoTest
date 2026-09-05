#!/bin/bash

# 导入NPU锁管理器
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/npu_lock_manager_for_ci.sh"
LOCK_DIR="/home/zkjh/.npu_locks"
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
LOCAL_IP=$(hostname -I | xargs printf "%s\n" | head -n 1)
SERVER_NAME=$(echo $LOCAL_IP | sed 's/\./_/g')

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
    TAGS=$(/home/zkjh/jfrog rt curl \
        --server-id=my-jcr \
        /api/docker/docker-local/v2/siginfer-aarch64-moore/tags/list \
    | jq -r '.tags[]' | sort)

    for tag in $TAGS; do
    created=$(/home/zkjh/jfrog rt curl \
        --server-id=my-jcr \
        /api/storage/docker-local/siginfer-aarch64-moore/$tag \
        | jq -r '.created')
    echo "$tag $created"
    done > tag_dates.txt

    LATEST_TAG=$(sort -k2 -r tag_dates.txt | grep main- | head -n1 | awk '{print $1}')
    echo "The latest version : $LATEST_TAG"
else
    LATEST_TAG=$VERSION
    echo "The specified version : $LATEST_TAG"
fi

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

docker_pull_with_retry "docker.xcoresigma.com/docker/siginfer-aarch64-moore:$LATEST_TAG" || exit 1

ret=`docker ps -a | grep siginfer_moore_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}`
if [ $? -eq 0 ]; then
  docker stop siginfer_moore_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}
  docker rm siginfer_moore_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT}
fi

# Slave节点需要等待Master节点的HTTP Server启动完成......
if [ $NODE_RANK -ne 0 ]; then
  sleep 30
fi

# 设置超时时间(单位:秒)
TIMEOUT=10
START_TIME=$(date +%s)

# 目标空闲 GPU 数量
if [ $GPU_QUANITY -eq 16 ]; then
    TARGET_FREE_GPUS=8
else
    TARGET_FREE_GPUS=$GPU_QUANITY
fi

# 检查 mthreads-gmi 命令是否存在
if ! command -v mthreads-gmi &> /dev/null; then
    echo "错误: mthreads-gmi 未找到，请确保 Moore S5000 驱动已安装"
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

    # 使用 mthreads-gmi 获取 GPU 使用情况（显存 >= 100MiB 视为占用）
    GPU_INFO=($(mthreads-gmi | awk '/^Processes:/{p=1; next} p && $1 ~ /^[0-9]+$/ {mem=$NF; gsub(/MiB/,"",mem); if (mem+0 >= 100) print $1}' | sort -nu))
    GPU_INFO=($(echo "${GPU_INFO[@]}" | tr ' ' '\n' | sort -u))
    USE_COUNT=$(echo "${GPU_INFO[@]}" | wc -w)
    echo "当前使用中的 GPU 数量：$USE_COUNT, 索引: ${GPU_INFO[@]}"
    TOTAL_COUNT=$(mthreads-gmi -L | wc -l)
    FREE_COUNT=$(($TOTAL_COUNT-$USE_COUNT))
    FREE_GPU_INFO=($(seq 0 $(($TOTAL_COUNT-1)) | grep -vxFf <(printf "%s\n" "${GPU_INFO[@]}")))
    echo "当前空闲 GPU 数量：$FREE_COUNT, 索引: ${FREE_GPU_INFO[@]}"
    if [ "$FREE_COUNT" -ge "$TARGET_FREE_GPUS" ]; then
        echo "发现 $TARGET_FREE_GPUS 张空闲 GPU, 索引: ${FREE_GPU_INFO[@]}"
        echo "尝试锁定其中 $TARGET_FREE_GPUS 张 GPU"
        if acquire_npu_locks_batch "$SERVER_NAME" "${FREE_GPU_INFO[*]}" "$TARGET_FREE_GPUS" "$TASK_ID" "$SESSION_ID" ACUQIRED_LOCKS; then
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

MUSA_VISIBLE_DEVICES=$(echo "${GPU_INFO[@]}" | sed -E 's/\s+/\,/g')
echo "MUSA_VISIBLE_DEVICES=$MUSA_VISIBLE_DEVICES"

LOG_NAME="server_log_<<<TEST_TYPE>>>_$(date +'%Y%m%d_%H%M%S').log"

MASTER_IP=`echo $SERVER_LIST | tr '_' '\n' | head -n 1`
if [ $LOCAL_IP == $MASTER_IP ]; then
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

    if [ -z $PORT ] || [ -z $PROMETHEUS_PORT ] || [ -z $MASTER_PORT ]; then
        exit 1
    fi

    echo "$LOCAL_IP:$JOB_ID:$PORT $PROMETHEUS_PORT $MASTER_PORT" >> "${LOCK_DIR}/server_config.txt"
    exec 200>&-
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

EXEC_COMMAND="docker run --name=siginfer_moore_<<<TEST_TYPE>>>_${SESSION_ID}_${JOB_COUNT} \
     -u root  \
     --privileged \
     --ipc=host \
     --network host \
     --pid host \
     --volume /dev:/dev \
     --volume /home:/home \
     --volume /home/zkjh/weight/:/home/weight/ \
     -e MUSA_VISIBLE_DEVICES=$MUSA_VISIBLE_DEVICES \
     -e SIG_LOG_LEVEL='warn,console_logger=info' \
     <<<ENV_VARS>>>
     docker.xcoresigma.com/docker/siginfer-aarch64-moore:$LATEST_TAG"

<<<generated source code>>>

echo "$EXEC_COMMAND"

eval "$EXEC_COMMAND"
if [ $? -ne 0 ]; then
  exit 1;
fi

TIMEOUT_SECONDS=$((60*30))
if [ $NODE_RANK -eq 0 ]; then
    timeout $TIMEOUT_SECONDS tail -F $LOG_NAME | grep --line-buffered -m 1 -E "INFO:\s+Application startup complete\."
    EXIT_STATUS=$?
    if [ $EXIT_STATUS -eq 124 ]; then
        echo "模型启动超时（${TIMEOUT_SECONDS}秒）"
    elif [ $EXIT_STATUS -eq 0 ]; then
        echo ">>> Detected master service startup completion!"
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
