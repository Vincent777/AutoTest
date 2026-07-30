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
TASK_ID="PerformanceTest_${MODEL}_${JOB_COUNT}"
JOB_ID="PerformanceTest_${MODEL}_${SESSION_ID}_${JOB_COUNT}"
LOCAL_IP=$(hostname -I | xargs printf "%s\n" | grep "10.0.0")
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

docker pull ${IMAGE_REPO}:$LATEST_TAG
if [ $? -ne 0 ]; then
    exit 1;
fi

ret=`docker ps -a | grep sglang_ascend_PerformanceTest_${SESSION_ID}_${JOB_COUNT}`
if [ $? -eq 0 ]; then
    docker stop sglang_ascend_PerformanceTest_${SESSION_ID}_${JOB_COUNT}
    docker rm sglang_ascend_PerformanceTest_${SESSION_ID}_${JOB_COUNT}
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

LOG_NAME="server_log_PerformanceTest_$(date +'%Y%m%d_%H%M%S').log"

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

EXEC_COMMAND="docker run --name=sglang_ascend_PerformanceTest_${SESSION_ID}_${JOB_COUNT} \
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
  -e ASCEND_RT_VISIBLE_DEVICES=$ASCEND_RT_VISIBLE_DEVICES  \
  ${IMAGE_REPO}:$LATEST_TAG"

if [ $MODEL == "DeepSeek-R1-Distill-Qwen-32B" ]; then
    echo "python3 -m sglang.launch_server --model-path /home/weight/DeepSeek-R1-Distill-Qwen-32B --served-model-name DeepSeek-R1-Distill-Qwen-32B --port $PORT --tp-size 2 --host 0.0.0.0 --context-length 18432 --disable-radix-cache"
    EXEC_COMMAND+=" python3 -m sglang.launch_server --model-path /home/weight/DeepSeek-R1-Distill-Qwen-32B --served-model-name DeepSeek-R1-Distill-Qwen-32B --port $PORT --tp-size 2 --host 0.0.0.0 --context-length 18432 --disable-radix-cache $SGLANG_PREFIX_CACHE > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Llama-8B" ]; then
    echo "python3 -m sglang.launch_server --model-path /home/weight/DeepSeek-R1-Distill-Llama-8B --served-model-name DeepSeek-R1-Distill-Llama-8B --port $PORT --tp-size 1 --host 0.0.0.0 --disable-radix-cache"
    EXEC_COMMAND+=" python3 -m sglang.launch_server --model-path /home/weight/DeepSeek-R1-Distill-Llama-8B --served-model-name DeepSeek-R1-Distill-Llama-8B --port $PORT --tp-size 1 --host 0.0.0.0 --disable-radix-cache $SGLANG_PREFIX_CACHE > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen3-32B-FP8" ]; then
    echo "python3 -m sglang.launch_server --model-path /home/weight/Qwen3/Qwen3-32B-FP8 --served-model-name Qwen3-32B-FP8 --port $PORT --tp-size 2 --host 0.0.0.0 --disable-radix-cache"
    EXEC_COMMAND+=" python3 -m sglang.launch_server --model-path /home/weight/Qwen3/Qwen3-32B-FP8 --served-model-name Qwen3-32B-FP8 --port $PORT --tp-size 2 --host 0.0.0.0 --disable-radix-cache $SGLANG_PREFIX_CACHE > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Llama-70B" ]; then
    echo "python3 -m sglang.launch_server --model-path /home/weight/DeepSeek-R1-Distill-Llama-70B --served-model-name DeepSeek-R1-Distill-Llama-70B --port $PORT --tp-size 4 --host 0.0.0.0 --disable-radix-cache"
    EXEC_COMMAND+=" python3 -m sglang.launch_server --model-path /home/weight/DeepSeek-R1-Distill-Llama-70B --served-model-name DeepSeek-R1-Distill-Llama-70B --port $PORT --tp-size 4 --host 0.0.0.0 --disable-radix-cache $SGLANG_PREFIX_CACHE > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen3-235B-A22B" ]; then
    echo "python3 -m sglang.launch_server --model-path /home/weight/Qwen3/Qwen3-235B-A22B --served-model-name Qwen3-235B-A22B --port $PORT --tp-size 8 --host 0.0.0.0 --mem-fraction-static 0.98 --disable-radix-cache"
    EXEC_COMMAND+=" python3 -m sglang.launch_server --model-path /home/weight/Qwen3/Qwen3-235B-A22B --served-model-name Qwen3-235B-A22B --port $PORT --tp-size 8 --host 0.0.0.0 --mem-fraction-static 0.98 --disable-radix-cache $SGLANG_PREFIX_CACHE > $LOG_NAME 2>&1 &"
fi

echo "$EXEC_COMMAND"

eval "$EXEC_COMMAND"
if [ $? -ne 0 ]; then
    exit 1;
fi

TIMEOUT_SECONDS=$((60*30))
if [ $NODE_RANK -eq 0 ]; then
    timeout $TIMEOUT_SECONDS tail -F $LOG_NAME | grep --line-buffered -m 1 -E "The server is fired up and ready to roll|Application startup complete"
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
