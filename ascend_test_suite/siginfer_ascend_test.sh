#!/bin/bash

# 接收参数
send_report=$1
server_list=($2)
candidate_models=$3
job_count=$4
TEST_TYPE=$5
ENGINE_TYPE=$6
session_id=$7

if [ $TEST_TYPE == "Performance" ]; then
    TEST_PARAM=$8
    version=$9
    num_of_prefix_cache_options=1
else
    version=$8
    if [ $TEST_TYPE == "Stability" ]; then
        num_of_prefix_cache_options=1
    else
        if [ $ENGINE_TYPE == "SigInfer" ]; then
            num_of_prefix_cache_options=2
        else
            num_of_prefix_cache_options=1
        fi
    fi
fi

curr_dir=$(pwd)
log_name_suffix=${TASK_START_TIME}
LOCK_DIR="/home/s_limingge/.npu_locks"
LOCK_FILE="server_config.lock"

if true; then
    if [ -z $version ]; then
        full_model_list=($(python3 $curr_dir/parse_model_list.py $curr_dir/latest/${ENGINE_TYPE}_model_list.xlsx))
    else
        full_model_list=($(python3 $curr_dir/parse_model_list.py $curr_dir/$version/${ENGINE_TYPE}_model_list.xlsx))
    fi
else
    full_model_list=(DeepSeek-R1-AWQ:8 DeepSeek-R1:16 DeepSeek-R1-0528:16 DeepSeek-R1-W8A8:16 DeepSeek-V3.1-Terminus-Channel-int8:16 DeepSeek-R1-Distill-Qwen-1.5B:1 DeepSeek-R1-Distill-Qwen-7B:1 DeepSeek-R1-Distill-Qwen-14B:1 DeepSeek-R1-Distill-Qwen-32B:2 DeepSeek-R1-Distill-Llama-8B:1 DeepSeek-R1-Distill-Llama-70B:4 Meta-Llama-3.1-8B-Instruct:1 Meta-Llama-3.1-70B-Instruct:4 Qwen2.5-0.5B-Instruct:1 Qwen2.5-1.5B-Instruct:1 Qwen2.5-3B-Instruct:1 Qwen2.5-7B-Instruct:1 Qwen2.5-14B-Instruct:1 Qwen2.5-32B-Instruct:2 Qwen2.5-72B-Instruct:4 QwQ-32B:2 Qwen2.5-0.5B-Instruct-AWQ:1 Qwen2.5-1.5B-Instruct-AWQ:1 Qwen2.5-3B-Instruct-AWQ:1 Qwen2.5-7B-Instruct-AWQ:1 Qwen2.5-14B-Instruct-AWQ:1 Qwen2.5-32B-Instruct-AWQ:1 Qwen2.5-72B-Instruct-AWQ:2 QwQ-32B-AWQ:1 Qwen3-32B:2 Qwen3-30B-A3B:2 Qwen3-235B-A22B:8 Qwen3-32B-AWQ:1 Qwen1.5-1.8B-Chat:1 ChatGLM-6B:1 chatglm2-6b:1 chatglm3-6b:1 baichuan-7B:1 Baichuan2-7B-Chat:1)
fi

declare -A npu_server_list=(
    ["10.9.1.78"]="AICC_001"
    ["10.9.1.106"]="AICC_003"
    ["10.9.1.114"]="AICC_004"
    ["10.9.1.98"]="AICC_005"
    ["10.9.1.110"]="AICC_006"
    ["10.9.1.86"]="AICC_007"
    ["10.9.1.94"]="AICC_008"
    ["10.9.1.82"]="AICC_009"
    ["10.9.1.102"]="AICC_010"
)

declare -A local_ip_map=(
    ["10.9.1.78"]="10.0.0.13"
    ["10.9.1.106"]="10.0.0.3"
    ["10.9.1.114"]="10.0.0.43"
    ["10.9.1.98"]="10.0.0.40"
    ["10.9.1.110"]="10.0.0.37"
    ["10.9.1.86"]="10.0.0.27"
    ["10.9.1.94"]="10.0.0.4"
    ["10.9.1.82"]="10.0.0.53"
    ["10.9.1.102"]="10.0.0.20"
)

# 数据面 → 管理面（CI/压测客户端可达 10.9.1.x，通常不可达 10.0.0.x）
declare -A mgmt_ip_map=()
for _mgmt in "${!local_ip_map[@]}"; do
    mgmt_ip_map["${local_ip_map[$_mgmt]}"]="$_mgmt"
done

# 若传入数据面 IP，转换为管理面；已是管理面则原样返回
to_mgmt_ip() {
    local ip="$1"
    if [ -n "${mgmt_ip_map[$ip]:-}" ]; then
        echo "${mgmt_ip_map[$ip]}"
    else
        echo "$ip"
    fi
}

if [ -z $send_report ]; then
    echo "Missing parameter!"
    exit 1
elif [[ ! "$send_report" =~ ^[0-9]+$ ]] || [[ $send_report -ne 1 && $send_report -ne 0 ]]; then
    echo "Parameter 1 is worng!"
    exit 1
fi

if [ -z $server_list ]; then
    echo "Missing parameters!"
    exit 1
fi

# PD 分离放置：host:role:id,... ；约束 P/D 不得同机
PD_TOPOLOGY="${PD_TOPOLOGY:-}"
PD_PLACEMENT="${PD_PLACEMENT:-}"
PD_ENGINE="${PD_ENGINE:-$(echo "${ENGINE_TYPE}" | tr '[:upper:]' '[:lower:]')}"
# Ascend 910B 无 IB：SGLang 默认 ascend；vLLM 默认 MooncakeConnector
PD_SGLANG_TRANSFER_BACKEND="${PD_SGLANG_TRANSFER_BACKEND:-ascend}"
PD_SGLANG_IB_DEVICE="${PD_SGLANG_IB_DEVICE:-}"
PD_VLLM_KV_CONNECTOR="${PD_VLLM_KV_CONNECTOR:-MooncakeConnector}"
ASCEND_MF_STORE_URL="${ASCEND_MF_STORE_URL:-}"
MF_CONFIG_STORE_URL="${MF_CONFIG_STORE_URL:-}"
# 保留用户显式注入值；每个模型 job 可按 JOB_ID 重新派生 store URL
ASCEND_MF_STORE_URL_USER="$ASCEND_MF_STORE_URL"
MF_CONFIG_STORE_URL_USER="$MF_CONFIG_STORE_URL"

if [ -n "$PD_TOPOLOGY" ]; then
    echo "PD mode enabled: topology=$PD_TOPOLOGY placement=$PD_PLACEMENT engine=$PD_ENGINE"
    if [ -z "$PD_PLACEMENT" ]; then
        echo "ERROR: PD_TOPOLOGY set but PD_PLACEMENT empty"
        exit 1
    fi
    if ! python3 "$curr_dir/pd_place_servers.py" --validate-placement "$PD_PLACEMENT"; then
        echo "ERROR: PD placement violates P/D anti-colocation"
        exit 1
    fi
    echo "PD transfer defaults: sglang_backend=$PD_SGLANG_TRANSFER_BACKEND vllm_connector=$PD_VLLM_KV_CONNECTOR mf_store=${ASCEND_MF_STORE_URL:-auto}"
fi

# 存储 Docker 容器名称
declare -a DOCKER_CONTAINER_NAMES

# 存储后台 ssh 进程 PID，用于信号传递
declare -A SSH_PID_MAP

# 从数组中删除指定元素的辅助函数
remove_container_from_array() {
    local value_to_remove=$1
    local new_array=()
    
    for item in "${DOCKER_CONTAINER_NAMES[@]}"; do
        if [ "$item" != "$value_to_remove" ]; then
            new_array+=("$item")
        fi
    done
    
    DOCKER_CONTAINER_NAMES=("${new_array[@]}")
    echo "已从跟踪列表中删除容器: $value_to_remove"
}

# PD：按 placement 停止各 P/D 实例容器及 router
stop_pd_engine_containers() {
    local jc="${1:-$job_count}"
    local ent pd_host rest pd_id suffix cname router_host

    if [ -z "${PD_PLACEMENT:-}" ]; then
        return 0
    fi

    IFS=',' read -ra _pd_stop_ents <<< "$PD_PLACEMENT"
    for ent in "${_pd_stop_ents[@]}"; do
        pd_host="${ent%%:*}"
        rest="${ent#*:}"
        pd_id="${rest##*:}"
        suffix="_${pd_id}"
        if [ "$ENGINE_TYPE" = "SigInfer" ]; then
            cname="siginfer_ascend_${TEST_TYPE}Test_${session_id}_${jc}${suffix}"
        elif [ "$ENGINE_TYPE" = "vLLM" ]; then
            cname="vllm_ascend_${TEST_TYPE}Test_${session_id}_${jc}${suffix}"
        elif [ "$ENGINE_TYPE" = "MindIE" ]; then
            cname="mindie_ascend_${TEST_TYPE}Test_${session_id}_${jc}${suffix}"
        elif [ "$ENGINE_TYPE" = "SGLang" ]; then
            cname="sglang_ascend_${TEST_TYPE}Test_${session_id}_${jc}${suffix}"
        else
            continue
        fi
        ssh -q -o ConnectionAttempts=3 s_limingge@"$pd_host" docker stop "$cname" 2>/dev/null || true
        ssh -q -o ConnectionAttempts=3 s_limingge@"$pd_host" docker rm "$cname" 2>/dev/null || true
        if [ -z "${router_host:-}" ]; then
            router_host="$pd_host"
        fi
    done

    router_host="${pd_router_coord_host:-$router_host}"
    if [ -n "$router_host" ]; then
        ssh -q -o ConnectionAttempts=3 s_limingge@"$router_host" \
            docker stop "pd_router_${TEST_TYPE}Test_${session_id}_${jc}" 2>/dev/null || true
        ssh -q -o ConnectionAttempts=3 s_limingge@"$router_host" \
            docker rm "pd_router_${TEST_TYPE}Test_${session_id}_${jc}" 2>/dev/null || true
    fi
}

# 统一由编排侧同步 Prometheus scrape targets（非 PD / PD 均在此触发）
sync_prometheus_scrape_targets() {
    local jid="${1:?job_id}"
    local script="${curr_dir}/../llm_perf_dashboard/prometheus_grafana/sync_prometheus_from_server_config.sh"

    if [ ! -f "$script" ]; then
        echo "WARN: prometheus sync script missing: $script"
        return 0
    fi
    echo ">>> Syncing Prometheus scrape targets (job_id=$jid)..."
    PD_ENGINE="$PD_ENGINE" bash "$script" --job-id "$jid" --engine "$PD_ENGINE" || \
        echo "WARN: prometheus sync returned non-zero (ignored)"
}

# 标志变量，用于跟踪是否由信号中断
INTERRUPTED=0

# 统一的清理函数 - 同时处理 NPU 锁、本地容器和远程容器
cleanup_all_resources() {
    engine_type=$(echo "${ENGINE_TYPE}" | tr '[:upper:]' '[:lower:]')
    echo ""
    echo "=========================================="
    echo "${engine_type}_ascend_test.sh 退出，开始清理资源..."
    echo "=========================================="
    
    # 1. 清理本地 Docker 容器
    if [ ${#DOCKER_CONTAINER_NAMES[@]} -gt 0 ]; then
        echo "正在清理本地 Docker 容器..."
        for container_name in "${DOCKER_CONTAINER_NAMES[@]}"; do
            if [ ! -z "$container_name" ]; then
                echo "  停止容器: $container_name"
                docker stop "$container_name" 2>/dev/null || true
                # docker rm -f "$container_name" 2>/dev/null || true
            fi
        done
        echo "本地容器清理完成"
    fi
    
    # 2. 释放 NPU 锁
    if [ -v model ]; then
        echo "正在释放 NPU 锁..."
        source $curr_dir/npu_lock_manager_for_ci.sh
        for ip in ${server_list[@]}; do
            SERVER_NAME=$(echo ${local_ip_map[$ip]} | sed 's/\./_/g')
            release_npu_locks_batch "$SERVER_NAME" "0 1 2 3 4 5 6 7" "${TEST_TYPE}Test_${model}_${job_count}" "${session_id}"
        done
        echo "NPU 锁释放完成"
        # 释放本 session 的主机 PD 角色租约
        if [ -n "${PD_TOPOLOGY:-}" ]; then
            echo "正在释放 host role leases (session=$session_id)..."
            python3 "$curr_dir/host_role_lease.py" release-session --session "$session_id" || true
        fi
        # 获取文件锁（阻塞）
        exec 200>"${LOCK_DIR}/${LOCK_FILE}"    # 打开文件描述符 200
        if ! flock -x 200; then    # 获取独占锁
            echo "无法获取锁，退出..."
        fi
        for ip in ${server_list[@]}; do
            job_id="${TEST_TYPE}Test_${model}_${session_id}_${job_count}"
            # 删除Server端配置信息
            # sed -i "/${local_ip_map[$ip]}:${job_id}:/d" "${LOCK_DIR}/server_config.txt"
            new_config=`sed "/${local_ip_map[$ip]}:${job_id}:/d" "${LOCK_DIR}/server_config.txt"`
            echo "${new_config}" > "${LOCK_DIR}/server_config.txt"
        done
        # 锁会自动在脚本退出或文件描述符关闭时释放
        exec 200>&-  # 关闭文件描述符
        echo "Server Config文件锁释放完成"
        exec 300>&-  # 关闭文件描述符
    fi
    
    # 3. 清理远程 Docker 容器
    if [ -n "${PD_PLACEMENT:-}" ]; then
        stop_pd_engine_containers "${job_count:-0}"
    else
        for ip in ${server_list[@]}; do
            ssh -q -o ConnectionAttempts=3 s_limingge@$ip "
                name=${engine_type}_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                if [ ! -z \"\$\(docker ps -a | grep \$name\)\" ]; then
                    docker stop \$name
                    docker rm \$name
                fi
            "
        done
    fi
    
    echo "=========================================="
    echo "资源清理完成"
    echo "=========================================="
    
    # 如果是由于信号中断，则退出进程
    if [ $INTERRUPTED -eq 1 ]; then
        echo "进程被中断，退出..."
        exit 130  # 130 是 Ctrl+C 的标准退出码 (128 + SIGINT的2)
    fi
}

# 信号处理函数
handle_interrupt() {
    INTERRUPTED=1
    echo ""
    echo "收到中断信号，正在向所有远程进程发送中断信号..."
    # 从 SSH_PID_MAP 中收集唯一的 IP 地址
    declare -A unique_ips
    for pid in "${!SSH_PID_MAP[@]}"; do
        remote_ip="${SSH_PID_MAP[$pid]}"
        unique_ips["$remote_ip"]=1
    done
    # 对每个唯一的 IP 地址，通过 ssh 找到并终止远程脚本进程
    for remote_ip in "${!unique_ips[@]}"; do
        echo "  向远程服务器 $remote_ip 上的脚本进程发送 SIGINT..."
        # 通过 ssh 找到远程脚本进程并发送信号
        ssh -o ConnectionAttempts=3 -o ConnectTimeout=5 s_limingge@$remote_ip "
            pids=\$(ps -ef --forest | grep '${ENGINE_TYPE}_job_executor_for_${TEST_TYPE}Test.sh' | grep -v grep | awk '{print \$2}' 2>/dev/null || true)
            if [ ! -z \"\$pids\" ]; then
                for pid in \$pids; do
                    # 检查进程是否仍在运行
                    if kill -0 \$pid 2>/dev/null; then
                        echo \"找到远程脚本进程 PID: \$pid, 发送 SIGINT 信号\"
                        kill -TERM -\$pid 2>/dev/null || true
                    fi
                done
            else
                echo \"未找到远程脚本进程（可能已结束）\"
            fi
        " 2>/dev/null || true
    done
    # 等待一小段时间，让远程脚本有机会处理信号
    sleep 2
    if [ -v JMETER_PID ]; then
        kill -SIGTERM $JMETER_PID
    fi
    cleanup_all_resources
}

# 注册信号处理函数
trap handle_interrupt SIGINT SIGTERM
# EXIT 信号仍然调用 cleanup（正常退出时 INTERRUPTED=0，不会额外 exit）
trap cleanup_all_resources EXIT

model_list=()

if [ ! -z "$candidate_models" ]; then
    for name in $candidate_models; do
        for item in "${full_model_list[@]}"; do
            model=`echo "$item" | awk -F : '{print $1}'`
            if [[ "$model" =~ ^$name$ ]]; then
                model_list+=($item)
            fi
        done
    done
else
    model_list=("${full_model_list[@]}")
fi

echo "*************开始执行${TEST_TYPE}测试任务，日期时间:$(date +"%Y%m%d_%H%M%S")***************"
echo "测试模型列表: ${model_list[@]}"

if [ -z $version ]; then
    version=$(jfrog rt curl --server-id=my-jcr /api/docker/docker-local/v2/siginfer-aarch64-ascend/tags/list | jq -r '.tags[]' \
                        | xargs -I% sh -c "echo -n \"%  \"; \
                            jfrog rt curl --server-id=my-jcr \
                            /api/storage/docker-local/siginfer-aarch64-ascend/% \
                        | jq -r '.created'" | sort -k2 -r | grep main- | head -n1 | awk '{print $1}')
fi

echo "推理引擎版本: ${version}"

test_type=$(echo "${TEST_TYPE}" | tr '[:upper:]' '[:lower:]')
processed_models="${curr_dir}/logs/${test_type}/$session_id/processed_models_${log_name_suffix}"
touch ${processed_models}

# schedule_policies=('DynamicSplitFuseV2' 'PrefillFirst')
schedule_policies=('DynamicSplitFuseV2')
ret_code=0

for option in "${schedule_policies[@]}"; do
    use_prefix_cache_flag=-1
    for ((i=1; i<=${num_of_prefix_cache_options}; i=i+1)); do
        swap_space=0
        for ((j=1; j<=1; j=j+1)); do
            for item in "${model_list[@]}"; do
                model=`echo "$item" | awk -F : '{print $1}'`
                gpu_quantity=`echo "$item" | awk -F : '{print $2}'`

                # 模型已经测试过了，检查下一个
                if [ $use_prefix_cache_flag -gt 0 ]; then
                    if [ $swap_space -eq 0 ]; then
                        if [ ! -z `cat ${processed_models} | grep -w ${model}_${option}_use-prefix-cache` ]; then
                            continue
                        fi
                    else
                        if [ ! -z `cat ${processed_models} | grep -w ${model}_${option}_use-prefix-cache_swap-space` ]; then
                            continue
                        fi
                    fi
                else
                    if [ $swap_space -eq 0 ]; then
                        if [ ! -z `cat ${processed_models} | grep -w ${model}_${option}` ]; then
                            continue
                        fi
                    else
                        if [ ! -z `cat ${processed_models} | grep -w ${model}_${option}_swap-space` ]; then
                            continue
                        fi
                    fi
                fi

                filename=${log_name_suffix}_${model}_
                if [ $use_prefix_cache_flag -eq 1 ]; then
                    if [ $swap_space -eq 0 ]; then
                        echo "开始测试模型: $model, 启动选项: --schedule-policy $option, --use-prefix-cache"
                        filename+=${option}"_use-prefix-cache"
                    else
                        echo "开始测试模型: $model, 启动选项: --schedule-policy $option, --use-prefix-cache, --swap-space=40"
                        filename+=${option}"_use-prefix-cache_swap-space"
                    fi
                else
                    if [ $swap_space -eq 0 ]; then 
                        echo "开始测试模型: $model, 启动选项: --schedule-policy $option"
                        filename+=${option}
                    else
                        echo "开始测试模型: $model, 启动选项: --schedule-policy $option, --swap-space=40"
                        filename+=${option}"_swap-space"
                    fi
                fi

                cd $curr_dir

                if [ $TEST_TYPE != "Accuracy" ]; then
                    filename+=".log"
                fi

                echo "尝试同时在${server_list[@]}服务器上面启动测试......"
                
                # 将 server_list 数组合并为用下划线分隔的字符串（非 PD / TP 多机）
                server_list_str=$(
                    for i in "${server_list[@]}"; do
                        printf '%s\n' "${local_ip_map[$i]}"
                    done | paste -sd '_' -
                )

                unset pid_map
                declare -A pid_map
                seq_num=0

                pd_router_coord_host=""
                pd_router_coord_local_ip=""

                launch_executor() {
                    local ip=$1
                    local rank=$2
                    local slist=$3
                    local pd_role=$4
                    local log_suffix=$5
                    local remote_cmd
                    local pd_env_prefix=""
                    if [ $ENGINE_TYPE == "MindIE" ]; then
                        remote_cmd="/home/s_limingge/${ENGINE_TYPE}_job_executor_for_${TEST_TYPE}Test.sh $model $gpu_quantity $slist $rank $job_count $session_id $version"
                    else
                        remote_cmd="/home/s_limingge/${ENGINE_TYPE}_job_executor_for_${TEST_TYPE}Test.sh $model $gpu_quantity $use_prefix_cache_flag $option $swap_space $slist $rank $job_count $session_id $version"
                    fi
                    if [ -n "$PD_TOPOLOGY" ]; then
                        pd_env_prefix="PD_TOPOLOGY=${PD_TOPOLOGY} PD_ROLE=${pd_role} PD_ENGINE=${PD_ENGINE} PD_INSTANCE_ID=${log_suffix}"
                        if [ "$ENGINE_TYPE" = "SGLang" ] || [ "$PD_ENGINE" = "sglang" ]; then
                            pd_env_prefix="${pd_env_prefix} PD_SGLANG_TRANSFER_BACKEND=${PD_SGLANG_TRANSFER_BACKEND}"
                            if [ -n "$PD_SGLANG_IB_DEVICE" ]; then
                                pd_env_prefix="${pd_env_prefix} PD_SGLANG_IB_DEVICE=${PD_SGLANG_IB_DEVICE}"
                            fi
                            if [ -n "$ASCEND_MF_STORE_URL" ]; then
                                pd_env_prefix="${pd_env_prefix} ASCEND_MF_STORE_URL=${ASCEND_MF_STORE_URL}"
                                pd_env_prefix="${pd_env_prefix} MF_CONFIG_STORE_URL=${MF_CONFIG_STORE_URL:-$ASCEND_MF_STORE_URL}"
                            fi
                        fi
                        if [ "$ENGINE_TYPE" = "vLLM" ] || [ "$PD_ENGINE" = "vllm" ]; then
                            pd_env_prefix="${pd_env_prefix} PD_VLLM_KV_CONNECTOR=${PD_VLLM_KV_CONNECTOR}"
                        fi
                        remote_cmd="${pd_env_prefix} ${remote_cmd}"
                    fi
                    if [ $TEST_TYPE == "Smoke" ]; then
                        ssh -q -o ConnectionAttempts=3 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 s_limingge@$ip \
                          "bash -lc $(printf '%q' "$remote_cmd")" \
                          > "$curr_dir/logs/smoke/$session_id/${filename}_${log_suffix}" &
                    else
                        ssh -q -o ConnectionAttempts=3 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 s_limingge@$ip \
                          "bash -lc $(printf '%q' "$remote_cmd")" &
                    fi
                    ssh_pid=$!
                    pid_map[$ssh_pid]=$ip
                    SSH_PID_MAP[$ssh_pid]=$ip
                }

                if [ -n "$PD_TOPOLOGY" ] && [ -n "$PD_PLACEMENT" ]; then
                    # 每个模型 job 重置为用户注入值，再按需派生（避免多模型共用同一 store 端口）
                    ASCEND_MF_STORE_URL="$ASCEND_MF_STORE_URL_USER"
                    MF_CONFIG_STORE_URL="$MF_CONFIG_STORE_URL_USER"
                    # SGLang ascend 后端：为本次 job 生成统一 ASCEND_MF_STORE_URL（所有 P/D 共用）
                    if { [ "$ENGINE_TYPE" = "SGLang" ] || [ "$PD_ENGINE" = "sglang" ]; } \
                        && [ "$PD_SGLANG_TRANSFER_BACKEND" = "ascend" ] \
                        && [ -z "$ASCEND_MF_STORE_URL" ]; then
                        mf_store_host_ip=""
                        IFS=',' read -ra _mf_ents <<< "$PD_PLACEMENT"
                        for ent in "${_mf_ents[@]}"; do
                            _mf_host="${ent%%:*}"
                            _mf_rest="${ent#*:}"
                            _mf_role="${_mf_rest%%:*}"
                            if [ "$_mf_role" = "prefill" ]; then
                                mf_store_host_ip="${local_ip_map[$_mf_host]}"
                                break
                            fi
                        done
                        if [ -z "$mf_store_host_ip" ]; then
                            _mf_first="${_mf_ents[0]%%:*}"
                            mf_store_host_ip="${local_ip_map[$_mf_first]}"
                        fi
                        if [ -z "$mf_store_host_ip" ]; then
                            echo "ERROR: cannot derive ASCEND_MF_STORE_URL host from PD_PLACEMENT"
                            exit 1
                        fi
                        job_id_key="${TEST_TYPE}Test_${model}_${session_id}_${job_count}"
                        mf_store_port=$((24669 + $(printf '%s' "$job_id_key" | cksum | awk '{print $1 % 2000}')))
                        ASCEND_MF_STORE_URL="tcp://${mf_store_host_ip}:${mf_store_port}"
                        MF_CONFIG_STORE_URL="$ASCEND_MF_STORE_URL"
                        echo "Derived ASCEND_MF_STORE_URL=$ASCEND_MF_STORE_URL (job=$job_id_key)"
                    fi
                    if [ -n "$ASCEND_MF_STORE_URL" ] && [ -z "$MF_CONFIG_STORE_URL" ]; then
                        MF_CONFIG_STORE_URL="$ASCEND_MF_STORE_URL"
                    fi
                    # PD：每台机独立实例（本机 local_ip 作为 SERVER_LIST），NODE_RANK=0，注入 PD_ROLE
                    IFS=',' read -ra _pd_ents <<< "$PD_PLACEMENT"
                    for ent in "${_pd_ents[@]}"; do
                        pd_host="${ent%%:*}"
                        rest="${ent#*:}"
                        pd_role="${rest%%:*}"
                        pd_id="${rest##*:}"
                        local_only="${local_ip_map[$pd_host]}"
                        if [ -z "$local_only" ]; then
                            echo "ERROR: no local_ip_map for PD host $pd_host"
                            exit 1
                        fi
                        if [ -z "$local_master_ip" ]; then
                            local_master_ip=$local_only
                        fi
                        if [ "$pd_role" = "prefill" ] && [ -z "$pd_router_coord_host" ]; then
                            pd_router_coord_host="$pd_host"
                            pd_router_coord_local_ip="$local_only"
                        fi
                        echo "启动 PD 实例 ${pd_id} role=${pd_role} on $pd_host (local=$local_only)......"
                        launch_executor "$pd_host" 0 "$local_only" "$pd_role" "${pd_id}"
                        ((seq_num++))
                    done
                else
                    # 依次在所有服务器上面启动任务（TP 多机 / 单机）
                    for ip in ${server_list[@]}; do
                        echo "启动第${seq_num}台服务器: $ip......"

                        if [ $ip == ${server_list[0]} ]; then
                            local_master_ip=${local_ip_map[$ip]}
                        fi

                        launch_executor "$ip" "$seq_num" "$server_list_str" "" "$seq_num"
                        ((seq_num++))
                    done
                fi

                # 接收各个节点的rank_table.json并进行合并与分发
                if [ $ENGINE_TYPE == "MindIE" ]; then
                    job_id="${TEST_TYPE}Test_${model}_${session_id}_${job_count}"
                    mkdir -p $curr_dir/controller/$job_id
                    cd $curr_dir/controller/$job_id
                    rm -rf *
                    npm init -y
                    npm install express multer
                    cp $curr_dir/controller.js .
                    # 获取文件锁（阻塞），防止多任务并发执行时发生端口冲突
                    exec 300>"${LOCK_DIR}/http_port_$((8080+$job_count)).lock"    # 打开文件描述符 300
                    if ! flock -x 300; then    # 获取独占锁
                        echo "无法获取锁，退出..."
                        exit 1
                    fi
                    node controller.js $((8080+$job_count)) ${#server_list[@]}
                    # 锁会自动在脚本退出或文件描述符关闭时释放
                    exec 300>&-  # 关闭文件描述符
                    arguments=""
                    for ip in ${server_list[@]}; do
                        node_name=$(echo ${local_ip_map[$ip]} | sed 's/\./_/g')
                        arguments+=" ./ranks/${node_name}.json"
                    done
                    python3 $curr_dir/merge_hccl.py $arguments
                    merged_rank_table=`ls hccl_*.json`
                    if [ ! -f $merged_rank_table ]; then
                        echo "Rank Table文件合并失败，无法找到输出文件..."
                        exit 1
                    fi
                    for ip in ${server_list[@]}; do
                        scp $merged_rank_table s_limingge@$ip:/home/s_limingge/rank_table/$job_id/merged_rank_table.json
                    done
                    cd $curr_dir
                fi

                success=0
                # 等待所有服务器任务启动完成
                if [ -n "$PD_TOPOLOGY" ] && [ -n "$PD_PLACEMENT" ]; then
                    remaining=$(echo "$PD_PLACEMENT" | tr ',' '\n' | grep -c . || true)
                else
                    remaining=${#server_list[@]}
                fi
                while (( remaining > 0 )); do
                    wait -n -p done_pid
                    err=$?
                    
                    if [ -v pid_map[$done_pid] ]; then
                        echo "任务启动结束，服务器：${pid_map[$done_pid]} (PID=$done_pid)"

                        # 从 SSH_PID_MAP 中移除已完成的进程
                        unset SSH_PID_MAP[$done_pid]
                        
                        if [ $err -ne 0 ]; then
                            if [ $err -eq 10 ]; then
                                echo "${pid_map[$done_pid]}暂无资源, 中止当前模型测试任务，尝试进行下一个测试任务......"
                            else
                                echo "${pid_map[$done_pid]}测试环境配置失败, 中止当前模型测试任务，尝试进行下一个测试任务......"
                            fi
                            
                            # ...

                            # 启动失败，清理工作
                            if [ -n "${PD_PLACEMENT:-}" ]; then
                                stop_pd_engine_containers "$job_count"
                            else
                            for ip in ${server_list[@]}; do
                                if [ $ENGINE_TYPE == "SigInfer" ]; then
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop siginfer_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm siginfer_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                elif [ $ENGINE_TYPE == "vLLM" ]; then
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop vllm_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm vllm_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                elif [ $ENGINE_TYPE == "MindIE" ]; then
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop mindie_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm mindie_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                elif [ $ENGINE_TYPE == "SGLang" ]; then
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop sglang_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                    ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm sglang_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                                fi
                            done
                            fi
                            
                            ret_code=$err
                            success=1
                            break
                        fi

                        ((remaining--))
                    else
                        echo "PID=${done_pid}不在pid_map中, 致命错误!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                    fi
                done

                # 任务启动失败
                if [ $success -eq 1 ]; then
                    continue
                fi

                job_id="${TEST_TYPE}Test_${model}_${session_id}_${job_count}"

                # PD：P/D 就绪后启动 Router/Proxy，压测走 proxy 入口
                if [ -n "$PD_TOPOLOGY" ] && [ -n "$PD_PLACEMENT" ]; then
                    if [ -z "$pd_router_coord_host" ] || [ -z "$pd_router_coord_local_ip" ]; then
                        echo "ERROR: cannot determine PD router coordinator from placement"
                        stop_pd_engine_containers "$job_count"
                        ret_code=1
                        continue
                    fi
                    echo ">>> Launching PD router on ${pd_router_coord_host} (${pd_router_coord_local_ip})..."
                    if ! bash "$curr_dir/pd_launch_router.sh" \
                        "$ENGINE_TYPE" "$TEST_TYPE" "$session_id" "$job_count" "$model" "$version" \
                        "$pd_router_coord_host" "$pd_router_coord_local_ip" "$job_id" "$PD_TOPOLOGY"; then
                        echo "ERROR: PD router launch failed"
                        stop_pd_engine_containers "$job_count"
                        ret_code=1
                        continue
                    fi
                fi

                # 非 PD：全部节点就绪后 sync；PD：router 注册 proxy 后 sync
                sync_prometheus_scrape_targets "$job_id"

                if [ -f "${LOCK_DIR}/${LOCK_FILE}" ]; then
                    # 获取文件锁（阻塞）
                    exec 200>"${LOCK_DIR}/${LOCK_FILE}"    # 打开文件描述符 200
                    if ! flock -x 200; then    # 获取独占锁
                        echo "无法获取锁，退出..."
                        exit 1
                    fi
                    # 读取 Server 端配置：PD 模式优先 proxy 入口，否则 master
                    if [ -n "$PD_TOPOLOGY" ]; then
                        read -r local_master_ip server_port < <(python3 "$curr_dir/pd_router.py" get-proxy --job-id "$job_id" 2>/dev/null || true)
                        if [ -z "$local_master_ip" ] || [ -z "$server_port" ]; then
                            echo "WARN: proxy entry missing, fallback to first prefill port"
                            server_port=`cat "${LOCK_DIR}/server_config.txt" | grep "${job_id}:" | grep "role=prefill" | awk -F ':' '{print $3}' | awk '{print $1}' | head -n 1`
                            local_master_ip=`cat "${LOCK_DIR}/server_config.txt" | grep "${job_id}:" | grep "role=prefill" | awk -F ':' '{print $1}' | head -n 1`
                        fi
                        # 压测从编排机发起：统一走管理面 IP（10.9.1.x）
                        local_master_ip=$(to_mgmt_ip "$local_master_ip")
                        echo "PD benchmark entry: http://${local_master_ip}:${server_port}"
                    else
                        server_port=`cat "${LOCK_DIR}/server_config.txt" | grep "${local_master_ip}:${job_id}:" | awk -F ':' '{print $3}' | awk '{print $1}' | tail -n 1`
                        # 非 PD 历史逻辑写的是数据面；压测同样映射到管理面
                        local_master_ip=$(to_mgmt_ip "$local_master_ip")
                    fi
                    # 锁会自动在脚本退出或文件描述符关闭时释放
                    exec 200>&-  # 关闭文件描述符
                else
                    echo "无法找到远端推理引擎服务端口号文件！中止此模型测试任务！"
                    if [ $ENGINE_TYPE == "SigInfer" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop siginfer_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm siginfer_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    elif [ $ENGINE_TYPE == "vLLM" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop vllm_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm vllm_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    elif [ $ENGINE_TYPE == "MindIE" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop mindie_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm mindie_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    elif [ $ENGINE_TYPE == "SGLang" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop sglang_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm sglang_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    fi
                    continue
                fi

                echo "开始执行模型${TEST_TYPE}测试任务......"

                if [ $TEST_TYPE == "Smoke" ]; then
                    # 获取模型启动命令，并做为参数传入
                    exec_cmd=""
                    for ((k=0; k<$seq_num; k=k+1)); do
                        launch_cmd=`tail -n 4 "$curr_dir/logs/smoke/$session_id/${filename}_${k}" | head -n 1`
                        exec_cmd+="$launch_cmd\n"
                    done

                    full_cmd=${exec_cmd%??}
                    container_name="OpenaiTest_$$"

                    if [ $use_prefix_cache_flag -eq 1 ]; then
                        if [ $swap_space -eq 0 ]; then
                            model_name=${model}_${option}_Use-prefix-cache
                        else
                            model_name=${model}_${option}_Use-prefix-cache_Swap-space
                        fi
                    else
                        if [ $swap_space -eq 0 ]; then
                            model_name=${model}_${option}
                        else
                            model_name=${model}_${option}_Swap-space
                        fi
                    fi

                    unset pid_map
                    declare -A pid_map
                    
                    echo "docker run --rm --name $container_name --volume $curr_dir/report_${log_name_suffix}/$session_id:/test/report_${log_name_suffix} -e TASK_START_TIME=${log_name_suffix} --entrypoint /test/start.sh openai:1110 --file $filename --email limingge@xcoresigma.com --env=${npu_server_list[${server_list[0]}]} --url http://${server_list[0]}:${server_port}/v1 --model=$model_name --gpu 910B --cmd \"$full_cmd\""
                    docker run --rm --name $container_name --volume $curr_dir/report_${log_name_suffix}/$session_id:/test/report_${log_name_suffix} -e TASK_START_TIME=${log_name_suffix} --entrypoint /test/start.sh openai:1110 --file $filename --email limingge@xcoresigma.com --env=${npu_server_list[${server_list[0]}]} --url http://${server_list[0]}:${server_port}/v1 --model=$model_name --gpu 910B --cmd "\"$full_cmd\"" 2>&1 &
                    pid=$!
                    pid_map[$pid]="$container_name"
                    DOCKER_CONTAINER_NAMES+=("$container_name")

                    # 等待后台测试任务结束
                    wait -n -p done_pid
                    err=$?
                    if [ -v pid_map[$done_pid] ]; then
                        echo "测试任务：${pid_map[$done_pid]}结束!"
                        if [ $err -ne 0 ]; then
                            echo "测试结果失败！请检查......"
                        fi
                        # 从跟踪数组中删除已完成的容器
                        remove_container_from_array "${pid_map[$done_pid]}"
                        unset pid_map[$done_pid]
                    fi
                elif [ $TEST_TYPE == "Performance" ]; then
                    if [ $model == "Qwen3-235B-A22B" ] || [[ $model =~ ^Qwen3-32B(-v[0-9]+)?$ ]] || [ $model == "Qwen3-30B-A3B" ] || [ $model == "Qwen3-14B" ]; then
                        data_path="/home/weight/Qwen3"
                    else
                        data_path="/home/weight"
                    fi

                    if [ $ENGINE_TYPE == "SigInfer" ]; then
                        engine_type="siginfer"
                        benchmark_cmd="python3 /SigInfer/script/benchmark/benchmark_serving.py"
                    elif [ $ENGINE_TYPE == "vLLM" ]; then
                        engine_type="vllm"
                        benchmark_cmd="vllm bench serve"
                    elif [ $ENGINE_TYPE == "MindIE" ]; then
                        engine_type="mindie"
                        benchmark_cmd="vllm bench serve"
                    elif [ $ENGINE_TYPE == "SGLang" ]; then
                        engine_type="sglang"
                        benchmark_cmd="python3 -m sglang.benchmark.serving"
                    fi
                    
                    # 开始执行测试
                    if [ $TEST_PARAM == "Random" ]; then
                        multiplier=4
                        concurrency_list=(1 5 10 20 50 100 150 200)
                        length_pairs=(
                            "128:128"
                            "128:1024"
                            "128:2048"
                            "1024:1024"
                            "2048:2048"
                            "4096:1024"
                            "1024:4096"
                            # "30000:2048"
                            # "126000:2048"
                        )
                        # Random
                        ssh -q -o ConnectionAttempts=3 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 s_limingge@${server_list[0]} "
                            docker exec ${engine_type}_ascend_PerformanceTest_${session_id}_${job_count} /bin/bash -c \"
                                if [ ${engine_type} == \\\"siginfer\\\" ]; then
                                    pip3 install dataSets pillow aiohttp
                                elif [ ${engine_type} == \\\"mindie\\\" ]; then
                                    python3 -m venv venv_vllm
                                    source venv_vllm/bin/activate
                                    unset PYTHONPATH
                                    pip3 install vllm
                                fi

                                for pair in ${length_pairs[@]}; do
                                    input_len=\\\$(echo \\\$pair | cut -d ':' -f 1)
                                    output_len=\\\$(echo \\\$pair | cut -d ':' -f 2)

                                    echo \\\"========================================================\\\"
                                    echo \\\"Random Testing input=\\\$input_len, output=\\\$output_len\\\"
                                    echo \\\"========================================================\\\"

                                    for concurrency in ${concurrency_list[@]}; do
                                        # Avoid obvious over-context random cases that only generate warnings/noisy logs.
                                        if [ ${engine_type} == \\\"sglang\\\" ] && [ \\\$input_len -gt 16000 ]; then
                                            echo \\\"Skip input_len=\\\$input_len for sglang random (over safe context budget)\\\"
                                            break
                                        fi
                                        if [ \\\$input_len -ge 30000 ] && [ \\\$concurrency -gt 5 ]; then
                                            break
                                        fi
                                        
                                        prompts=\\\$((concurrency * ${multiplier}))
                                        echo \\\"Testing concurrency=\\\$concurrency, prompts=\\\$prompts\\\"
                                        if [ ${engine_type} == \\\"sglang\\\" ]; then
                                            echo \\\"python3 -m sglang.benchmark.serving --backend sglang --host ${local_master_ip} --port ${server_port} --model ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ --tokenizer ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ --dataset-name random --dataset-path /home/s_limingge/ShareGPT_V3_unfiltered_cleaned_split.json --random-input-len \\\$input_len --random-output-len \\\$output_len --num-prompts \\\$prompts --request-rate inf --max-concurrency \\\$concurrency\\\"
                                            python3 -m sglang.benchmark.serving \
                                            --backend sglang \
                                            --host ${local_master_ip} \
                                            --port ${server_port} \
                                            --model ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ \
                                            --tokenizer ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ \
                                            --dataset-name random \
                                            --dataset-path /home/s_limingge/ShareGPT_V3_unfiltered_cleaned_split.json \
                                            --random-input-len \\\$input_len \
                                            --random-output-len \\\$output_len \
                                            --num-prompts \\\$prompts \
                                            --request-rate inf \
                                            --max-concurrency \\\$concurrency
                                        else
                                            echo \\\"${benchmark_cmd} --backend openai --port ${server_port} --host ${local_master_ip} --model ${model} --tokenizer ${data_path}/${model}/ --endpoint /v1/completions --dataset-name random --random-input-len \\\$input_len --random-output-len \\\$output_len --num-prompts \\\$prompts --request-rate inf --max-concurrency \\\$concurrency --ignore-eos\\\"
                                            ${benchmark_cmd} \
                                            --backend openai \
                                            --port ${server_port} \
                                            --host ${local_master_ip} \
                                            --model ${model} \
                                            --tokenizer ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ \
                                            --endpoint /v1/completions \
                                            --dataset-name random \
                                            --random-input-len \\\$input_len \
                                            --random-output-len \\\$output_len \
                                            --num-prompts \\\$prompts \
                                            --request-rate inf \
                                            --max-concurrency \\\$concurrency \
                                            --ignore-eos
                                        fi
                                    done
                                done
                            \"
                        " > "$curr_dir/logs/performance/$session_id/$filename"
                    else
                        concurrency_list=(100 200 300 400 500 600 700 800 900 1000)
                        # Sharegpt
                        ssh -q -o ConnectionAttempts=3 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 s_limingge@${server_list[0]} "
                            docker exec ${engine_type}_ascend_PerformanceTest_${session_id}_${job_count} /bin/bash -c \"
                                if [ ${engine_type} == \\\"siginfer\\\" ]; then
                                    pip3 install dataSets pillow aiohttp
                                elif [ ${engine_type} == \\\"mindie\\\" ]; then
                                    python3 -m venv venv_vllm
                                    source venv_vllm/bin/activate
                                    unset PYTHONPATH
                                    pip3 install vllm
                                fi

                                for concurrency in ${concurrency_list[@]}; do
                                    prompts=\\\$((concurrency * 4))
                                    echo \\\"Testing concurrency=\\\$concurrency, prompts=\\\$prompts\\\"
                                    if [ ${engine_type} == \\\"sglang\\\" ]; then
                                        echo \\\"python3 -m sglang.benchmark.serving --backend sglang --host ${local_master_ip} --port ${server_port} --model ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ --tokenizer ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ --dataset-name sharegpt --dataset-path /home/s_limingge/ShareGPT_V3_unfiltered_cleaned_split.json --num-prompts \\\$prompts --request-rate inf --max-concurrency \\\$concurrency\\\"
                                        python3 -m sglang.benchmark.serving \
                                        --backend sglang \
                                        --host ${local_master_ip} \
                                        --port ${server_port} \
                                        --model ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ \
                                        --tokenizer ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ \
                                        --dataset-name sharegpt \
                                        --dataset-path /home/s_limingge/ShareGPT_V3_unfiltered_cleaned_split.json \
                                        --num-prompts \\\$prompts \
                                        --request-rate inf \
                                        --max-concurrency \\\$concurrency
                                    else
                                        echo \\\"${benchmark_cmd} --backend openai --port ${server_port} --host ${local_master_ip} --model ${model} --tokenizer ${data_path}/${model}/ --endpoint /v1/completions --dataset-name sharegpt --dataset-path /home/s_limingge/ShareGPT_V3_unfiltered_cleaned_split.json --num-prompts \\\$prompts --request-rate inf --max-concurrency \\\$concurrency\\\"
                                        ${benchmark_cmd} \
                                        --backend openai \
                                        --port ${server_port} \
                                        --host ${local_master_ip} \
                                        --model ${model} \
                                        --tokenizer ${data_path}/$(echo $model | sed -E 's/-v[0-9]+$//')/ \
                                        --endpoint /v1/completions \
                                        --dataset-name sharegpt \
                                        --dataset-path /home/s_limingge/ShareGPT_V3_unfiltered_cleaned_split.json \
                                        --num-prompts \\\$prompts \
                                        --request-rate inf \
                                        --max-concurrency \\\$concurrency
                                    fi
                                done
                            \"
                        " > "$curr_dir/logs/performance/$session_id/$filename"
                    fi
                elif [ $TEST_TYPE == "Accuracy" ]; then
                    unset pid_map
                    declare -A pid_map
                    
                    # 开始执行测试
                    # 容器1: Evalscope mmlu,ceval
                    container_name_1="Evalscope_mmlu_ceval_$$"
                    docker run -i --rm --name "$container_name_1" --privileged=true --cap-add=ALL --pid=host --gpus=all --network=host  -v /home/weight/:/home/weight/ --entrypoint /evalscope.sh  evalscope:0624 -M $model --port ${server_port} --host ${server_list[0]} --number 10 -P 10 --dataset mmlu,ceval > "$curr_dir/logs/accuracy/$session_id/${filename}_evalscope_1.log" 2>&1 &
                    pid1=$!
                    pid_map[$pid1]="$container_name_1"
                    DOCKER_CONTAINER_NAMES+=("$container_name_1")
                    
                    # 容器2: Evalscope gsm8k,ARC_c
                    container_name_2="Evalscope_gsm8k_ARC_c_$$"
                    docker run -i --rm --name "$container_name_2" --privileged=true --cap-add=ALL --pid=host --gpus=all --network=host  -v /home/weight/:/home/weight/ --entrypoint /evalscope.sh  evalscope:0624 -M $model --port ${server_port} --host ${server_list[0]} --number 200 -P 10 --dataset gsm8k,ARC_c > "$curr_dir/logs/accuracy/$session_id/${filename}_evalscope_2.log" 2>&1 &
                    pid2=$!
                    pid_map[$pid2]="$container_name_2"
                    DOCKER_CONTAINER_NAMES+=("$container_name_2")

                    if [ $ENGINE_TYPE == "SGLang" ]; then
                        remaining=2
                    else
                        # 容器3: SGLang mmlu,gsm8k（对比 SigInfer/vLLM/MindIE 服务端）
                        container_name_3="SGLang_mmlu_gsm8k_$$"
                        docker run -i --rm --name "$container_name_3" --privileged=true --cap-add=ALL --pid=host --gpus=all --network=host  -v /home/weight/:/home/weight/ --entrypoint /sglang.sh  evalscope:0624 -M $model --port ${server_port} --host ${server_list[0]} > "$curr_dir/logs/accuracy/$session_id/${filename}_SGLang_3.log" 2>&1 &
                        pid3=$!
                        pid_map[$pid3]="$container_name_3"
                        DOCKER_CONTAINER_NAMES+=("$container_name_3")
                        remaining=3
                    fi
                    
                    # 等待所有后台测试任务结束
                    while (( remaining > 0 )); do
                        wait -n -p done_pid
                        err=$?

                        if [ -v pid_map[$done_pid] ]; then
                            echo "测试任务：${pid_map[$done_pid]}结束!"
                            if [ $err -ne 0 ]; then
                                echo "测试结果失败！请检查......"
                            fi
                            # 从跟踪数组中删除已完成的容器
                            remove_container_from_array "${pid_map[$done_pid]}"
                            unset pid_map[$done_pid]
                        fi

                        ((remaining--))
                    done

                    touch "$curr_dir/report_${log_name_suffix}/$session_id/${log_name_suffix}_result.txt"

                    eval_res_1=$(tail -n 1 "$curr_dir/logs/accuracy/$session_id/${filename}_evalscope_1.log")
                    eval_res_2=$(tail -n 1 "$curr_dir/logs/accuracy/$session_id/${filename}_evalscope_2.log")
                    if [ $ENGINE_TYPE == "SGLang" ]; then
                        sglang_res_3="$eval_res_2"
                    else
                        sglang_res_3=$(tail -n 5 "$curr_dir/logs/accuracy/$session_id/${filename}_SGLang_3.log")
                    fi
                    
                    if [ $use_prefix_cache_flag -eq 1 ]; then
                        if [ $swap_space -eq 0 ]; then
                            echo "${model}_${option}_Use-prefix-cache+$eval_res_1 $eval_res_2+${sglang_res_3//$'\n'/}" >> "$curr_dir/report_${log_name_suffix}/$session_id/${log_name_suffix}_result.txt"
                        else
                            echo "${model}_${option}_Use-prefix-cache_Swap-space+$eval_res_1 $eval_res_2+${sglang_res_3//$'\n'/}" >> "$curr_dir/report_${log_name_suffix}/$session_id/${log_name_suffix}_result.txt"
                        fi
                    else
                        if [ $swap_space -eq 0 ]; then
                            echo "${model}_${option}+$eval_res_1 $eval_res_2+${sglang_res_3//$'\n'/}" >> "$curr_dir/report_${log_name_suffix}/$session_id/${log_name_suffix}_result.txt"
                        else
                            echo "${model}_${option}_Swap-space+$eval_res_1 $eval_res_2+${sglang_res_3//$'\n'/}" >> "$curr_dir/report_${log_name_suffix}/$session_id/${log_name_suffix}_result.txt"
                        fi
                    fi
                elif [ $TEST_TYPE == "Stability" ]; then
                    # 调用JMeter或者Locust工具
                    export JVM_ARGS="-Xms4g -Xmx4g -XX:+UseG1GC"
                    jmeter -n -t smoke.jmx
                    jmeter -n -t test.jmx -l result.jtl
                    /opt/apache-jmeter-5.6.3/bin/jmeter \
                        -n \
                        -t /data/test/llm_perf.jmx \
                        -l /data/jtl/result_$(date +\%F).jtl  \
                        -e \
                        -o report/  \
                        -Jmodel=${model} \
                        -Jbatch_size=16 \
                        -Jcontext_len=8192 \
                        -Jqps=30    \
                        > /data/log/jmeter_$(date +\%F).log 2>&1 &

                        # 在 JMX 中使用：
                        # ${__P(model)}
                        # ${__P(batch_size)}
                        # ${__P(context_len)}

                        JMETER_PID=$!
                        wait $JMETER_PID
                fi

                echo "测试完成！"

                # 测试完成，清理工作
                if [ -n "${PD_PLACEMENT:-}" ]; then
                    stop_pd_engine_containers "$job_count"
                else
                for ip in ${server_list[@]}; do
                    if [ $ENGINE_TYPE == "SigInfer" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop siginfer_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm siginfer_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    elif [ $ENGINE_TYPE == "vLLM" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop vllm_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm vllm_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    elif [ $ENGINE_TYPE == "MindIE" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop mindie_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm mindie_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    elif [ $ENGINE_TYPE == "SGLang" ]; then
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker stop sglang_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                        ssh -q -o ConnectionAttempts=3 s_limingge@$ip docker rm sglang_ascend_${TEST_TYPE}Test_${session_id}_${job_count}
                    fi
                done
                fi

                # 释放本 job 的主机 PD 角色租约（同 session 其他并行 job 不受影响）
                if [ -n "${PD_TOPOLOGY:-}" ]; then
                    echo "释放 host role leases prefix=${session_id}:${job_count}:"
                    python3 "$curr_dir/host_role_lease.py" release-prefix --prefix "${session_id}:${job_count}:" || true
                fi
                
                # 发送测试报告
                if [ $send_report -eq 1 ]; then
                    latest_tag=$version
                    if [ $TEST_TYPE == "Smoke" ]; then
                        # 保存docker镜像版本信息
                        touch "$curr_dir/report_${log_name_suffix}/$session_id/version.txt"
                        echo "$latest_tag" > "$curr_dir/report_${log_name_suffix}/$session_id/version.txt"
                    elif [ $TEST_TYPE == "Performance" ]; then
                        # 保存docker镜像版本信息
                        touch "$curr_dir/report_${log_name_suffix}/$session_id/version.txt"
                        echo "$latest_tag" > "$curr_dir/report_${log_name_suffix}/$session_id/version.txt"
                        # 获取模型启动命令，并做为参数传入
                        exec_cmd=`cat "$curr_dir/logs/performance/$session_id/cron_job_${log_name_suffix}_${job_count}.log" | grep "docker run"`
                        # 获取测试命令，并做为参数传入
                        if [ $ENGINE_TYPE == "SigInfer" ]; then
                            test_cmd=`cat "$curr_dir/logs/performance/$session_id/$filename" | grep "benchmark_serving.py" | head -n 1 | sed -E 's/--(random-input-len|random-output-len|num-prompts|max-concurrency)\s+[0-9]+/--\1 xxx/g'`
                        elif [ $ENGINE_TYPE == "vLLM" ] || [ $ENGINE_TYPE == "MindIE" ]; then
                            test_cmd=`cat "$curr_dir/logs/performance/$session_id/$filename" | grep "vllm bench serve" | head -n 1 | sed -E 's/--(random-input-len|random-output-len|num-prompts|max-concurrency)\s+[0-9]+/--\1 xxx/g'`
                        elif [ $ENGINE_TYPE == "SGLang" ]; then
                            test_cmd=`cat "$curr_dir/logs/performance/$session_id/$filename" | grep "sglang.benchmark.serving" | head -n 1 | sed -E 's/--(random-input-len|random-output-len|num-prompts|max-concurrency)\s+[0-9]+/--\1 xxx/g'`
                        fi
                        # 生成本次测试的Excel报告，并比较上一次Excel报告
                        if [ $use_prefix_cache_flag -eq 1 ]; then
                            if [ $swap_space -eq 0 ]; then
                                python3 $curr_dir/WriteReportToExcel.py "$ENGINE_TYPE" "$TEST_PARAM" "${model}_${option}_Use-prefix-cache" "$session_id" "$exec_cmd" "$test_cmd" "$curr_dir/logs/performance/$session_id/$filename"
                                # last_date=$(date -d "$TASK_START_TIME -1 day" +"%Y%m%d")
                                # if [ -f $curr_dir/report_${last_date}/$session_id/version.txt ]; then
                                #     last_version=$(cat $curr_dir/report_${last_date}/$session_id/version.txt)
                                # else
                                #     last_version="unknown"
                                # fi
                                # if [ -f "$curr_dir/report_${last_date}/$session_id/${model}_${option}_Use-prefix-cache.xlsx" ]; then
                                #     python3 $curr_dir/compare_excel_data.py "${model}_${option}_Use-prefix-cache" "$latest_tag" "$curr_dir/report_${log_name_suffix}/$session_id/${model}_${option}_Use-prefix-cache.xlsx" "$last_version" "$curr_dir/report_${last_date}/$session_id/${model}_${option}_Use-prefix-cache.xlsx"
                                # fi
                            else
                                python3 $curr_dir/WriteReportToExcel.py "$ENGINE_TYPE" "$TEST_PARAM" "${model}_${option}_Use-prefix-cache_Swap-space" "$session_id" "$exec_cmd" "$test_cmd" "$curr_dir/logs/performance/$session_id/$filename"
                                # last_date=$(date -d "$TASK_START_TIME -1 day" +"%Y%m%d")
                                # if [ -f $curr_dir/report_${last_date}/$session_id/version.txt ]; then
                                #     last_version=$(cat $curr_dir/report_${last_date}/$session_id/version.txt)
                                # else
                                #     last_version="unknown"
                                # fi
                                # if [ -f "$curr_dir/report_${last_date}/$session_id/${model}_${option}_Use-prefix-cache_Swap-space.xlsx" ]; then
                                #     python3 $curr_dir/compare_excel_data.py "${model}_${option}_Use-prefix-cache_Swap-space" "$latest_tag" "$curr_dir/report_${log_name_suffix}/$session_id/${model}_${option}_Use-prefix-cache_Swap-space.xlsx" "$last_version" "$curr_dir/report_${last_date}/$session_id/${model}_${option}_Use-prefix-cache_Swap-space.xlsx"
                                # fi
                            fi
                        else
                            if [ $swap_space -eq 0 ]; then
                                python3 $curr_dir/WriteReportToExcel.py "$ENGINE_TYPE" "$TEST_PARAM" "${model}_${option}" "$session_id" "$exec_cmd" "$test_cmd" "$curr_dir/logs/performance/$session_id/$filename"
                                # last_date=$(date -d "$TASK_START_TIME -1 day" +"%Y%m%d")
                                # if [ -f $curr_dir/report_${last_date}/$session_id/version.txt ]; then
                                #     last_version=$(cat $curr_dir/report_${last_date}/$session_id/version.txt)
                                # else
                                #     last_version="unknown"
                                # fi
                                # if [ -f "$curr_dir/report_${last_date}/$session_id/${model}_${option}.xlsx" ]; then
                                #     python3 $curr_dir/compare_excel_data.py "${model}_${option}" "$latest_tag" "$curr_dir/report_${log_name_suffix}/$session_id/${model}_${option}.xlsx" "$last_version" "$curr_dir/report_${last_date}/$session_id/${model}_${option}.xlsx"
                                # fi
                            else
                                python3 $curr_dir/WriteReportToExcel.py "$ENGINE_TYPE" "$TEST_PARAM" "${model}_${option}_Swap-space" "$session_id" "$exec_cmd" "$test_cmd" "$curr_dir/logs/performance/$session_id/$filename"
                                # last_date=$(date -d "$TASK_START_TIME -1 day" +"%Y%m%d")
                                # if [ -f $curr_dir/report_${last_date}/$session_id/version.txt ]; then
                                #     last_version=$(cat $curr_dir/report_${last_date}/$session_id/version.txt)
                                # else
                                #     last_version="unknown"
                                # fi
                                # if [ -f "$curr_dir/report_${last_date}/$session_id/${model}_${option}_Swap-space.xlsx" ]; then
                                #     python3 $curr_dir/compare_excel_data.py "${model}_${option}_Swap-space" "$latest_tag" "$curr_dir/report_${log_name_suffix}/$session_id/${model}_${option}_Swap-space.xlsx" "$last_version" "$curr_dir/report_${last_date}/$session_id/${model}_${option}_Swap-space.xlsx"
                                # fi
                            fi
                        fi
                        mkdir -p ${LOCK_DIR}/artifacts/CI_ascend_test/${session_id}/performance
                        cp $curr_dir/report_${log_name_suffix}/${session_id}/* ${LOCK_DIR}/artifacts/CI_ascend_test/${session_id}/performance
                    fi
                fi
                
                # 记录测试进度
                if [ $use_prefix_cache_flag -eq 1 ]; then
                    if [ $swap_space -eq 0 ]; then
                        echo ${model}_${option}"_use-prefix-cache" >> ${processed_models}
                    else
                        echo ${model}_${option}"_use-prefix-cache_swap-space" >> ${processed_models}
                    fi
                else
                    if [ $swap_space -eq 0 ]; then
                        echo ${model}_${option} >> ${processed_models}
                    else
                        echo ${model}_${option}"_swap-space" >> ${processed_models}
                    fi
                fi
            done
            swap_space=40
        done
        use_prefix_cache_flag=$((-use_prefix_cache_flag))
    done
done

echo "测试全部完成！"

exit $ret_code
