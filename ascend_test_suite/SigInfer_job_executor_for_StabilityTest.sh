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
TASK_ID="StabilityTest_${MODEL}_${JOB_COUNT}"
JOB_ID="StabilityTest_${MODEL}_${SESSION_ID}_${JOB_COUNT}"
LOCAL_IP=$(hostname -I | xargs printf "%s\n" | grep "10.0.0" | head -n 1)
SERVER_NAME=$(echo $LOCAL_IP | sed 's/\./_/g')

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
    # 先拿到所有 tag 并按字母升序
    TAGS=$(/home/s_limingge/jfrog rt curl \
        --server-id=my-jcr \
        /api/docker/docker-local/v2/siginfer-aarch64-ascend/tags/list \
    | jq -r '.tags[]' | sort)

    # 遍历每个 tag，查询 Storage API 并输出 tag + 创建时间
    for tag in $TAGS; do
    created=$(/home/s_limingge/jfrog rt curl \
        --server-id=my-jcr \
        /api/storage/docker-local/siginfer-aarch64-ascend/$tag \
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

docker_pull_with_retry "docker.xcoresigma.com/docker/siginfer-aarch64-ascend:$LATEST_TAG" || exit 1

ret=`docker ps -a | grep siginfer_ascend_StabilityTest_${SESSION_ID}_${JOB_COUNT}`
if [ $? -eq 0 ]; then
  docker stop siginfer_ascend_StabilityTest_${SESSION_ID}_${JOB_COUNT}
  docker rm siginfer_ascend_StabilityTest_${SESSION_ID}_${JOB_COUNT}
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

LOG_NAME="server_log_StabilityTest_$(date +'%Y%m%d_%H%M%S').log"

MASTER_IP=`echo $SERVER_LIST | tr '_' '\n' | head -n 1`
if [ $LOCAL_IP == $MASTER_IP ]; then        # 获取Master节点的端口号
    # 获取文件锁（阻塞）
    exec 200>"${LOCK_DIR}/${LOCK_FILE}"    # 打开文件描述符 200
    if ! flock -x 200; then    # 获取独占锁
        echo "无法获取锁，退出..."
        exit 1
    fi

    # 确保文件存在 & 权限正确
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

    # 锁会自动在脚本退出或文件描述符关闭时释放
    exec 200>&-  # 关闭文件描述符
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

EXEC_COMMAND="docker run --name=siginfer_ascend_StabilityTest_${SESSION_ID}_${JOB_COUNT} \
     -u root  \
     -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64 	\
     -v /usr/local/Ascend/driver/include:/usr/local/Ascend/driver/include	\
     -v /usr/local/Ascend/driver/tools:/usr/local/Ascend/driver/tools 	\
     -v /usr/local/Ascend/driver:/usr/local/Ascend/driver   \
     -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi   \
     -v /dev/davinci0:/dev/davinci0      \
     -v /dev/davinci1:/dev/davinci1      \
     -v /dev/davinci2:/dev/davinci2      \
     -v /dev/davinci3:/dev/davinci3      \
     -v /dev/davinci4:/dev/davinci4      \
     -v /dev/davinci5:/dev/davinci5      \
     -v /dev/davinci6:/dev/davinci6      \
     -v /dev/davinci7:/dev/davinci7      \
     --volume /home:/home   \
     --volume /home/weight/:/home/weight/    \
     --volume /shared/weights:/shared/weights    \
     --network host      \
     --privileged \
     --device=/dev/davinci_manager \
     --device=/dev/devmm_svm       \
     --device=/dev/hisi_hdc        \
     --ipc=host	\
     -e HCCL_SOCKET_IFNAME=enp67s0f0 \
     -e ASCEND_RT_VISIBLE_DEVICES=$ASCEND_RT_VISIBLE_DEVICES    \
     docker.xcoresigma.com/docker/siginfer-aarch64-ascend:$LATEST_TAG"

if [ $MODEL == "DeepSeek-R1-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1-AWQ --tokenizer /home/weight/DeepSeek-R1-AWQ/ -tp 8 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY  --max-num-batched-tokens 8192 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --quantization awq  $SWAP_SPACE_OPTION --gpu-memory-utilization 0.92 --tool-call-parser deepseek_v3 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1-AWQ --tokenizer /home/weight/DeepSeek-R1-AWQ/ -tp 8 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY  --max-num-batched-tokens 8192 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --quantization awq  $SWAP_SPACE_OPTION --gpu-memory-utilization 0.92 --tool-call-parser deepseek_v3 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1 --tokenizer /home/weight/DeepSeek-R1/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1 --tokenizer /home/weight/DeepSeek-R1/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-0528" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1-0528 --tokenizer /home/weight/DeepSeek-R1-0528/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1-0528 --tokenizer /home/weight/DeepSeek-R1-0528/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-W8A8" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model DeepSeek-R1-W8A8 --tokenizer /home/weight/DeepSeek-R1-Channel-INT8/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --gpu-memory-utilization 0.97 --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3  --tokens-per-prediction 1 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model DeepSeek-R1-W8A8 --tokenizer /home/weight/DeepSeek-R1-Channel-INT8/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --gpu-memory-utilization 0.97 --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3  --tokens-per-prediction 1 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-V3.1-Terminus-Channel-int8" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model DeepSeek-V3.1-Terminus-Channel-int8 --tokenizer /home/weight/DeepSeek-V3.1-Terminus-Channel-int8/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --gpu-memory-utilization 0.97 --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3  --tokens-per-prediction 1 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model DeepSeek-V3.1-Terminus-Channel-int8 --tokenizer /home/weight/DeepSeek-V3.1-Terminus-Channel-int8/ -tp 16 --port $PORT --platform-type ascend --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --gpu-memory-utilization 0.97 --max-num-batched-tokens 2048 --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 2 --node-rank $NODE_RANK $SWAP_SPACE_OPTION --tool-call-parser deepseek_v3  --tokens-per-prediction 1 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Qwen-1.5B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1-Distill-Qwen-1.5B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-1.5B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1-Distill-Qwen-1.5B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-1.5B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Qwen-7B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1-Distill-Qwen-7B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-7B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1-Distill-Qwen-7B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-7B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Qwen-14B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1-Distill-Qwen-14B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-14B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1-Distill-Qwen-14B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-14B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Qwen-32B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model DeepSeek-R1-Distill-Qwen-32B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model DeepSeek-R1-Distill-Qwen-32B --tokenizer /home/weight/DeepSeek-R1-Distill-Qwen-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Llama-8B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1-Distill-Llama-8B --tokenizer /home/weight/DeepSeek-R1-Distill-Llama-8B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1-Distill-Llama-8B --tokenizer /home/weight/DeepSeek-R1-Distill-Llama-8B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "DeepSeek-R1-Distill-Llama-70B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model DeepSeek-R1-Distill-Llama-70B --tokenizer /home/weight/DeepSeek-R1-Distill-Llama-70B -tp 4 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model DeepSeek-R1-Distill-Llama-70B --tokenizer /home/weight/DeepSeek-R1-Distill-Llama-70B -tp 4 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Meta-Llama-3.1-8B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Meta-Llama-3.1-8B-Instruct --tokenizer /home/weight/Meta-Llama-3.1-8B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Meta-Llama-3.1-8B-Instruct --tokenizer /home/weight/Meta-Llama-3.1-8B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Meta-Llama-3.1-70B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Meta-Llama-3.1-70B-Instruct --tokenizer /home/weight/Meta-Llama-3.1-70B-Instruct -tp 4 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Meta-Llama-3.1-70B-Instruct --tokenizer /home/weight/Meta-Llama-3.1-70B-Instruct -tp 4 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser llama3_json $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-0.5B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-0.5B-Instruct --tokenizer /home/weight/Qwen2.5-0.5B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-0.5B-Instruct --tokenizer /home/weight/Qwen2.5-0.5B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-1.5B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model Qwen2.5-1.5B-Instruct --tokenizer /home/weight/Qwen2.5-1.5B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model Qwen2.5-1.5B-Instruct --tokenizer /home/weight/Qwen2.5-1.5B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-3B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-3B-Instruct --tokenizer /home/weight/Qwen2.5-3B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-3B-Instruct --tokenizer /home/weight/Qwen2.5-3B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-7B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh   --model Qwen2.5-7B-Instruct --tokenizer /home/weight/Qwen2.5-7B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="   --model Qwen2.5-7B-Instruct --tokenizer /home/weight/Qwen2.5-7B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-14B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-14B-Instruct --tokenizer /home/weight/Qwen2.5-14B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-14B-Instruct --tokenizer /home/weight/Qwen2.5-14B-Instruct -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-32B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-32B-Instruct --tokenizer /home/weight/Qwen2.5-32B-Instruct -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-32B-Instruct --tokenizer /home/weight/Qwen2.5-32B-Instruct -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-72B-Instruct" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-72B-Instruct --tokenizer /home/weight/Qwen2.5-72B-Instruct -tp 4 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-72B-Instruct --tokenizer /home/weight/Qwen2.5-72B-Instruct -tp 4 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "QwQ-32B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model QwQ-32B --tokenizer /home/weight/QwQ-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model QwQ-32B --tokenizer /home/weight/QwQ-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-0.5B-Instruct-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-0.5B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-0.5B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-0.5B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-0.5B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-1.5B-Instruct-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-1.5B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-1.5B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-1.5B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-1.5B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-3B-Instruct-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-3B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-3B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-3B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-3B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-7B-Instruct-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-7B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-7B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-7B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-7B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-14B-Instruct-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-14B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-14B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-14B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-14B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-32B-Instruct-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-32B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-32B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-32B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-32B-Instruct-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen2.5-72B-Instruct-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen2.5-72B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-72B-Instruct-AWQ -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen2.5-72B-Instruct-AWQ --tokenizer /home/weight/Qwen2.5-72B-Instruct-AWQ -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "QwQ-32B-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model QwQ-32B-AWQ --tokenizer /home/weight/QwQ-32B-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model QwQ-32B-AWQ --tokenizer /home/weight/QwQ-32B-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen3-32B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen3-32B --tokenizer /home/weight/Qwen3/Qwen3-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen3-32B --tokenizer /home/weight/Qwen3/Qwen3-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen3-30B-A3B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen3-30B-A3B --tokenizer /home/weight/Qwen3/Qwen3-30B-A3B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen3-30B-A3B --tokenizer /home/weight/Qwen3/Qwen3-30B-A3B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen3-235B-A22B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen3-235B-A22B --tokenizer /home/weight/Qwen3/Qwen3-235B-A22B -tp 8 --block-size 128 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --gpu-memory-utilization 0.96 --split-embedding --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen3-235B-A22B --tokenizer /home/weight/Qwen3/Qwen3-235B-A22B -tp 8 --block-size 128 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --gpu-memory-utilization 0.96 --split-embedding --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen3-32B-AWQ" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen3-32B-AWQ --tokenizer /home/weight/Qwen3/Qwen3-32B-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen3-32B-AWQ --tokenizer /home/weight/Qwen3/Qwen3-32B-AWQ -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION --tool-call-parser hermes $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen1.5-1.8B-Chat" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh  --model Qwen1.5-1.8B-Chat --tokenizer /home/weight/Qwen1.5-1.8B-Chat -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+="  --model Qwen1.5-1.8B-Chat --tokenizer /home/weight/Qwen1.5-1.8B-Chat -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT  --master-addr $MASTER_IP --master-port $MASTER_PORT  --nnodes 1 --node-rank $NODE_RANK --platform-type ascend  $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "ChatGLM-6B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh --model ChatGLM-6B --tokenizer /home/weight/ChatGLM-6B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+=" --model ChatGLM-6B --tokenizer /home/weight/ChatGLM-6B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "chatglm2-6b" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh --model chatglm2-6b --tokenizer /home/weight/chatglm2-6b -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+=" --model chatglm2-6b --tokenizer /home/weight/chatglm2-6b -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "chatglm3-6b" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh --model chatglm3-6b --tokenizer /home/weight/chatglm3-6b -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+=" --model chatglm3-6b --tokenizer /home/weight/chatglm3-6b -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "baichuan-7B" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh --model baichuan-7B --tokenizer /home/weight/baichuan-7B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+=" --model baichuan-7B --tokenizer /home/weight/baichuan-7B -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Baichuan2-7B-Chat" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh --model Baichuan2-7B-Chat --tokenizer /home/weight/Baichuan2-7B-Chat -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+=" --model Baichuan2-7B-Chat --tokenizer /home/weight/Baichuan2-7B-Chat -tp 1 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 2048 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
elif [ $MODEL == "Qwen3-32B-v2" ]; then
    echo "SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh --model Qwen3-32B-v2 --tokenizer /home/weight/Qwen3/Qwen3-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION --tool-call-parser hermes --use-model-v2 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT"
    EXEC_COMMAND+=" --model Qwen3-32B-v2 --tokenizer /home/weight/Qwen3/Qwen3-32B -tp 2 --block-size 128 --weight-dtype=FP16 --schedule-policy $SCHEDULE_POLICY --max-num-batched-tokens 8192 --port $PORT --master-addr $MASTER_IP --master-port $MASTER_PORT --nnodes 1 --node-rank $NODE_RANK --platform-type ascend $SWAP_SPACE_OPTION --tool-call-parser hermes --use-model-v2 $USE_PREFIX_CACHE --prometheus-port $PROMETHEUS_PORT > $LOG_NAME 2>&1 &"
fi

echo "$EXEC_COMMAND"

eval "$EXEC_COMMAND"
if [ $? -ne 0 ]; then
  exit 1;
fi

TIMEOUT_SECONDS=$((60*30)) # 设置启动超时时间为30分钟
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

# 超时时间（30分钟）
# TIMEOUT=$((10 * 60))
# START_TIME=$(date +%s)

# while true; do
#     # 检查超时
#     CURRENT_TIME=$(date +%s)
#     ELAPSED=$((CURRENT_TIME - START_TIME))
#     if [ $ELAPSED -ge $TIMEOUT ]; then
#         echo ">>> 超时（${TIMEOUT}秒）。服务可能未正确启动。" >&2
#         exit 1
#     fi

#     # 检查日志
#     if tail -n 50 "$LOG_FILE" | grep -q "Engine core initialization failed" "$LOG_FILE"; then
#         echo ">>> 检测到服务启动失败！"
#         exit 5
#     fi

#     if tail -n 50 "$LOG_FILE" | grep -Eq "INFO:\s+Application startup complete\."; then
#         echo ">>> 检测到服务启动完成！"
#         exit 0
#     fi

#     sleep 5
# done
