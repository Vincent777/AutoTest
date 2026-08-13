#!/bin/bash

# 捕获 SIGINT (Ctrl+C)、SIGTERM、SIGHUP (SSH Disconn)、SIGPIPE 和 EXIT 信号
# trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT
cleanup() {
    trap - SIGINT SIGTERM SIGHUP SIGPIPE
    kill -- -$$
    exit 130
}

trap cleanup SIGINT SIGTERM SIGHUP SIGPIPE

TEST_TYPE=$1
ENGINE_TYPE=$2
MODEL_LIST=$3
SESSION_ID=$4
curr_dir=$(pwd)

if [ -z $TEST_TYPE ]; then
    echo "Parameter Test_Type required!"
    exit 1
elif [ $TEST_TYPE != "Smoke" ] && [ $TEST_TYPE != "Performance" ] && [ $TEST_TYPE != "Stability" ] && [ $TEST_TYPE != "Accuracy" ]; then
    echo "Test_Type is wrong!"
    exit 1
fi

if [ -z $ENGINE_TYPE ]; then
    echo "Parameter PLATFORM required!"
    exit 1
elif [ $ENGINE_TYPE != "SigInfer" ] && [ $ENGINE_TYPE != "vLLM" ] && [ $ENGINE_TYPE != "MindIE" ] && [ $ENGINE_TYPE != "SGLang" ]; then
    echo "Inference Engine Type is wrong!"
    exit 1
fi

if [ -z $MODEL_LIST ]; then
    echo "Parameter Model List required!"
    exit 1
fi

if [ $TEST_TYPE == "Performance" ]; then
    TEST_PARAM=$5
    version=$6
    if [ -z $TEST_PARAM ]; then
        echo "Parameter Test_Param required!"
        exit 1
    elif [ $TEST_PARAM != "Random" ] && [ $TEST_PARAM != "SharedGPT" ]; then
        echo "Test_Param is wrong!"
        exit 1
    fi
else
    version=$5
fi

# PD 分离（可选）：PD_TOPOLOGY=2P2D 时按「同角色可共机、P/D 不可混部」选机
# 默认允许同角色堆叠（跨 CI job 通过 host_role_lease 共享主机角色）
PD_TOPOLOGY="${PD_TOPOLOGY:-}"
PD_ALLOW_SAME_ROLE_COLOCATE="${PD_ALLOW_SAME_ROLE_COLOCATE:-1}"
# 角色失衡/资源不足时最多空等轮次（每轮 sleep PD_SEARCH_RETRY_SEC）；0=不限制
PD_SEARCH_MAX_ROUNDS="${PD_SEARCH_MAX_ROUNDS:-60}"
PD_SEARCH_RETRY_SEC="${PD_SEARCH_RETRY_SEC:-10}"
# 启动搜索前清理超过该秒数的陈旧角色租约（崩溃未释放）；0=不清理
PD_LEASE_MAX_AGE="${PD_LEASE_MAX_AGE:-86400}"
PD_PLACEMENT=""
PD_SEARCH_FAIL_ROUNDS=0
PD_LAST_SEARCH_REASON=""

if [ $ENGINE_TYPE == "SigInfer" ]; then
    declare -A npu_server_list=(
        ["aicc001"]="10.9.1.78"
        ["aicc003"]="10.9.1.106"
        # ["aicc004"]="10.9.1.114"
        # ["aicc005"]="10.9.1.98"
        # ["aicc006"]="10.9.1.110"
        ["aicc007"]="10.9.1.86"
        ["aicc008"]="10.9.1.94"
        # ["aicc009"]="10.9.1.82"
        # ["aicc010"]="10.9.1.102"
    )
    if [ -z $version ]; then
        python3 $curr_dir/script_generator_for_SigInfer.py ${TEST_TYPE} "latest"
    else
        python3 $curr_dir/script_generator_for_SigInfer.py ${TEST_TYPE} $version
    fi
elif [ $ENGINE_TYPE == "vLLM" ]; then
    declare -A npu_server_list=(
        ["aicc001"]="10.9.1.78"
        ["aicc003"]="10.9.1.106"
        # ["aicc004"]="10.9.1.114"
        # ["aicc005"]="10.9.1.98"
        # ["aicc006"]="10.9.1.110"
        ["aicc007"]="10.9.1.86"
        ["aicc008"]="10.9.1.94"
        # ["aicc009"]="10.9.1.82"
        # ["aicc010"]="10.9.1.102"
    )
    if [ -z $version ]; then
        python3 $curr_dir/script_generator_for_vLLM.py ${TEST_TYPE} "latest"
    else
        python3 $curr_dir/script_generator_for_vLLM.py ${TEST_TYPE} $version
    fi
elif [ $ENGINE_TYPE == "MindIE" ]; then
    declare -A npu_server_list=(
        ["aicc001"]="10.9.1.78"
        ["aicc003"]="10.9.1.106"
        # ["aicc004"]="10.9.1.114"
        # ["aicc005"]="10.9.1.98"
        # ["aicc006"]="10.9.1.110"
        ["aicc007"]="10.9.1.86"
        ["aicc008"]="10.9.1.94"
        # ["aicc009"]="10.9.1.82"
        # ["aicc010"]="10.9.1.102"
    )
    if [ -z $version ]; then
        python3 $curr_dir/script_generator_for_MindIE.py ${TEST_TYPE} "latest"
    else
        python3 $curr_dir/script_generator_for_MindIE.py ${TEST_TYPE} $version
    fi
elif [ $ENGINE_TYPE == "SGLang" ]; then
    declare -A npu_server_list=(
        ["aicc001"]="10.9.1.78"
        ["aicc003"]="10.9.1.106"
        # ["aicc004"]="10.9.1.114"
        # ["aicc005"]="10.9.1.98"
        # ["aicc006"]="10.9.1.110"
        ["aicc007"]="10.9.1.86"
        ["aicc008"]="10.9.1.94"
        # ["aicc009"]="10.9.1.82"
        # ["aicc010"]="10.9.1.102"
    )
    if [ -z $version ]; then
        python3 $curr_dir/script_generator_for_SGLang.py ${TEST_TYPE} "latest"
    else
        python3 $curr_dir/script_generator_for_SGLang.py ${TEST_TYPE} $version
    fi
fi

full_model_list_for_smoke=(DeepSeek-R1-AWQ:8 DeepSeek-R1-W8A8:16 DeepSeek-R1-Distill-Qwen-1.5B:1 DeepSeek-R1-Distill-Qwen-32B:2 DeepSeek-R1-Distill-Llama-8B:1 DeepSeek-R1-Distill-Llama-70B:4 Meta-Llama-3.1-8B-Instruct:1 Meta-Llama-3.1-70B-Instruct:4 Qwen2.5-0.5B-Instruct:1 Qwen2.5-72B-Instruct:4 QwQ-32B:2 Qwen2.5-0.5B-Instruct-AWQ:1 Qwen2.5-72B-Instruct-AWQ:2 QwQ-32B-AWQ:1 Qwen3-32B:4 Qwen3-30B-A3B:2 Qwen3-235B-A22B:8 Qwen3-32B-v2:2 Qwen3-14B:2 DeepSeek-R1-Distill-Qwen-14B:2)
full_model_list_for_performance=(DeepSeek-R1-Distill-Qwen-32B:2 DeepSeek-R1-W8A8:16 DeepSeek-R1-AWQ:8 DeepSeek-R1-0528:16 Qwen3-235B-A22B:8 Qwen3-32B:4 Qwen2.5-72B-Instruct:4 Qwen2.5-72B-Instruct-AWQ:2 Qwen3-32B-v2:2 Qwen3-14B:2 DeepSeek-R1-Distill-Qwen-14B:2)
# full_model_list_for_performance=(DeepSeek-R1-0528:16 DeepSeek-R1-Distill-Qwen-32B:2 DeepSeek-R1-Distill-Llama-8B:1 Qwen3-32B:4 Qwen3-235B-A22B:8 DeepSeek-R1-W8A8:16)
full_model_list_for_accuracy=(DeepSeek-R1-AWQ:8 DeepSeek-R1-W8A8:16 DeepSeek-R1-Distill-Qwen-1.5B:1 Qwen3-235B-A22B:8 DeepSeek-R1-Distill-Qwen-32B:2 DeepSeek-R1-Distill-Llama-8B:1 DeepSeek-R1-Distill-Llama-70B:4 Meta-Llama-3.1-8B-Instruct:1 Qwen2.5-72B-Instruct-AWQ:2 Qwen2.5-32B-Instruct-AWQ:1 Qwen2.5-72B-Instruct:4 Meta-Llama-3.1-70B-Instruct:4 Qwen2.5-0.5B-Instruct:1 QwQ-32B:2 Qwen2.5-0.5B-Instruct-AWQ:1 QwQ-32B-AWQ:1 Qwen3-32B:4 Qwen3-30B-A3B:2 Qwen3-14B:2 DeepSeek-R1-Distill-Qwen-14B:2)
full_model_list_for_stability=(DeepSeek-R1-Distill-Qwen-32B:2 DeepSeek-R1:16 DeepSeek-R1-AWQ:8)

log_name_suffix=$(date +"%Y%m%d")
export TASK_START_TIME=${log_name_suffix}
parallel=3

mkdir -p $curr_dir/logs/accuracy/$SESSION_ID $curr_dir/logs/stability/$SESSION_ID $curr_dir/logs/performance/$SESSION_ID $curr_dir/logs/smoke/$SESSION_ID
mkdir -p $curr_dir/report_${log_name_suffix}/$SESSION_ID

if [ $TEST_TYPE == "Smoke" ]; then
    if [ $MODEL_LIST == "default" ]; then
        full_model_list=(${full_model_list_for_smoke[@]})
    else
        model_list=($(echo "$MODEL_LIST" | tr ',' ' '))
        full_model_list=()
        for model in "${model_list[@]}"; do
            for item in "${full_model_list_for_smoke[@]}"; do
                name=`echo "$item" | awk -F : '{print $1}'`
                if [ $model == $name ]; then
                    full_model_list+=($item)
                fi
            done
        done
    fi
    rm -rf $curr_dir/logs/smoke/$SESSION_ID/*.log $curr_dir/logs/smoke/$SESSION_ID/*.log_* $curr_dir/logs/smoke/$SESSION_ID/processed_models_*
    processed_models=${curr_dir}/logs/smoke/$SESSION_ID/"processed_models"_${log_name_suffix}
    touch ${processed_models}
    num_of_prefix_cache_options=2
elif [ $TEST_TYPE == "Performance" ]; then
    if [ $MODEL_LIST == "default" ]; then
        full_model_list=(${full_model_list_for_performance[@]})
    else
        model_list=($(echo "$MODEL_LIST" | tr ',' ' '))
        full_model_list=()
        for model in "${model_list[@]}"; do
            for item in "${full_model_list_for_performance[@]}"; do
                name=`echo "$item" | awk -F : '{print $1}'`
                if [ $model == $name ]; then
                    full_model_list+=($item)
                fi
            done
        done
    fi
    rm -rf $curr_dir/logs/performance/$SESSION_ID/*.log $curr_dir/logs/performance/$SESSION_ID/processed_models_*
    processed_models=${curr_dir}/logs/performance/$SESSION_ID/"processed_models"_${log_name_suffix}
    touch ${processed_models}
    num_of_prefix_cache_options=1
elif [ $TEST_TYPE == "Stability" ]; then
    full_model_list=(${full_model_list_for_stability[@]})
    rm -rf $curr_dir/logs/stability/$SESSION_ID/*.log $curr_dir/logs/stability/$SESSION_ID/processed_models_*
    processed_models=${curr_dir}/logs/stability/$SESSION_ID/"processed_models"_${log_name_suffix}
    touch ${processed_models}
    num_of_prefix_cache_options=1
elif [ $TEST_TYPE == "Accuracy" ]; then
    if [ $MODEL_LIST == "default" ]; then
        full_model_list=(${full_model_list_for_accuracy[@]})
    else
        model_list=($(echo "$MODEL_LIST" | tr ',' ' '))
        full_model_list=()
        for model in "${model_list[@]}"; do
            for item in "${full_model_list_for_accuracy[@]}"; do
                name=`echo "$item" | awk -F : '{print $1}'`
                if [ $model == $name ]; then
                    full_model_list+=($item)
                fi
            done
        done
    fi
    rm -rf $curr_dir/logs/accuracy/$SESSION_ID/*.log $curr_dir/logs/accuracy/$SESSION_ID/processed_models_*
    processed_models=${curr_dir}/logs/accuracy/$SESSION_ID/"processed_models"_${log_name_suffix}
    touch ${processed_models}
    num_of_prefix_cache_options=2
fi

search_servers() {
    local MODEL=$1
    local JOB_COUNT=$2
    local NPU_QUANTITY=$3
    local -n servers_found=$4     # 传名引用

    if [ $NPU_QUANTITY -lt 8 ]; then
        SERVER_QUANTITY=1
    else
        SERVER_QUANTITY=$(($NPU_QUANTITY/8))
    fi

    echo "正在搜索 ${SERVER_QUANTITY} 台GPU服务器......"
    
    servers_found=()
    for key in "${!npu_server_list[@]}"; do
        echo "$key => ${npu_server_list[$key]}"
        if [ $key == 'aicc002' ]; then
            sshpass -p 's_limingge' ssh -q -o ConnectionAttempts=3 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 s_limingge@${npu_server_list['aicc002']} "# 目标空闲 GPU 数量
                source /home/s_limingge/npu_lock_manager_for_ci.sh
                if [ $NPU_QUANTITY -eq 16 ]; then
                    TARGET_FREE_GPUS=8
                else
                    TARGET_FREE_GPUS=$NPU_QUANTITY
                fi
                echo \"开始在${key}上扫描 GPU, 目标: 寻找 \$TARGET_FREE_GPUS 张空闲 GPU...\"
                # 使用 npu-smi 获取 GPU 使用情况
                GPU_INFO=(\$(npu-smi info | grep \"No\ running\ processes\ found\ in\ NPU\" | awk '{print \$8}'))
                # 检查空闲 GPU 数量
                FREE_COUNT=\$(echo \"\${GPU_INFO[@]}\" | wc -w)
                echo \"当前空闲 GPU 数量：\$FREE_COUNT, 索引: \${GPU_INFO[@]}\"
                # 如果找到足够的空闲 GPU, 则返回结果并退出
                if [ \"\$FREE_COUNT\" -ge \"\$TARGET_FREE_GPUS\" ]; then
                    echo \"成功找到 \$TARGET_FREE_GPUS 张空闲 GPU, 索引：\${GPU_INFO[@]}\"
                    echo \"检查是否可以锁定其中 \$TARGET_FREE_GPUS 张 GPU\"
                    # 生成唯一的任务ID
                    TASK_ID=\"${TEST_TYPE}Test_${MODEL}_${JOB_COUNT}\"
                    LOCAL_IP=\$(hostname -I | xargs printf \"%s\\n\" | grep \"10.0.0\")
                    SERVER_NAME=\$(echo \$LOCAL_IP | sed 's/\./_/g')
                    check_npu_locks_batch \${SERVER_NAME} \"\${GPU_INFO[*]}\" \${TASK_ID} ${SESSION_ID} NPU_LIST_FOUND
                    if [ \${#NPU_LIST_FOUND[@]} -ge \$TARGET_FREE_GPUS ]; then
                        SELECTED_NPUS=\"\${NPU_LIST_FOUND[@]:0:\$TARGET_FREE_GPUS}\"
                        echo \"可以锁定其中 \$TARGET_FREE_GPUS 张 GPU, 索引：\${SELECTED_NPUS}\"
                        exit 0
                    else
                        echo \"锁定失败（可能被其他任务占用），继续扫描......\"
                    fi
                fi
                exit 1"
            err=$?
            if [ $err -eq 0 ]; then
                servers_found+=(${npu_server_list[$key]})
            fi
        else
            ssh -q -o ConnectionAttempts=3 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 s_limingge@${npu_server_list[$key]} "# 目标空闲 GPU 数量
                source /home/s_limingge/npu_lock_manager_for_ci.sh
                if [ $NPU_QUANTITY -eq 16 ]; then
                    TARGET_FREE_GPUS=8
                else
                    TARGET_FREE_GPUS=$NPU_QUANTITY
                fi
                echo \"开始在${key}上扫描 GPU, 目标: 寻找 \$TARGET_FREE_GPUS 张空闲 GPU...\"
                # 使用 npu-smi 获取 GPU 使用情况
                GPU_INFO=(\$(npu-smi info | grep \"No\ running\ processes\ found\ in\ NPU\" | awk '{print \$8}'))
                # if [ $NPU_QUANTITY -ne 16 ]; then
                #    过滤掉第7块和第8块GPU卡
                #    GPU_INFO=\$(echo \"\${GPU_INFO[@]}\" | sed -E 's/\b6\b//g' | sed -E 's/\b7\b//g' | sed -E 's/\s+/ /g' | xargs)
                # fi
                # 检查空闲 GPU 数量
                FREE_COUNT=\$(echo \"\${GPU_INFO[@]}\" | wc -w)
                echo \"当前空闲 GPU 数量：\$FREE_COUNT, 索引: \${GPU_INFO[@]}\"
                # 如果找到足够的空闲 GPU, 则返回结果并退出
                if [ \"\$FREE_COUNT\" -ge \"\$TARGET_FREE_GPUS\" ]; then
                    echo \"成功找到 \$TARGET_FREE_GPUS 张空闲 GPU, 索引：\${GPU_INFO[@]}\"
                    echo \"检查是否可以锁定其中 \$TARGET_FREE_GPUS 张 GPU\"
                    # 生成唯一的任务ID
                    TASK_ID=\"${TEST_TYPE}Test_${MODEL}_${JOB_COUNT}\"
                    LOCAL_IP=\$(hostname -I | xargs printf \"%s\\n\" | grep \"10.0.0\")
                    SERVER_NAME=\$(echo \$LOCAL_IP | sed 's/\./_/g')
                    check_npu_locks_batch \${SERVER_NAME} \"\${GPU_INFO[*]}\" \${TASK_ID} ${SESSION_ID} NPU_LIST_FOUND
                    if [ \${#NPU_LIST_FOUND[@]} -ge \$TARGET_FREE_GPUS ]; then
                        SELECTED_NPUS=\"\${NPU_LIST_FOUND[@]:0:\$TARGET_FREE_GPUS}\"
                        echo \"可以锁定其中 \$TARGET_FREE_GPUS 张 GPU, 索引：\${SELECTED_NPUS}\"
                        exit 0
                    else
                        echo \"锁定失败（可能被其他任务占用），继续扫描......\"
                    fi
                fi
                exit 1"
            err=$?
            if [ $err -eq 0 ]; then
                servers_found+=(${npu_server_list[$key]})
            fi
        fi

        if [ ${#servers_found[@]} -ge $SERVER_QUANTITY ]; then
            break
        fi
    done
}

# PD：扫描集群，结合 host_role_lease 做角色亲和放置，并 acquire 租约。
# 规则：同机可堆叠多个 CI job 的 P（或 D）；严禁 P/D 混部。
# 放置前会为 P/D 预留 idle 主机池，避免 Prefill 占满导致 Decode 饿死。
search_pd_servers() {
    local MODEL=$1
    local JOB_COUNT=$2
    local NPU_QUANTITY=$3
    local TOPOLOGY=$4
    local -n servers_found=$5
    local -n placement_out=$6

    servers_found=()
    placement_out=""
    PD_LAST_SEARCH_REASON=""

    local needed
    local place_req_args=(--topology "$TOPOLOGY" --required-hosts)
    if [ "$PD_ALLOW_SAME_ROLE_COLOCATE" != "1" ]; then
        place_req_args+=(--no-same-role-colocate)
    fi
    needed=$(python3 "$curr_dir/pd_place_servers.py" "${place_req_args[@]}")
    if [ -z "$needed" ] || [ "$needed" -lt 2 ]; then
        echo "ERROR: invalid PD_TOPOLOGY=$TOPOLOGY"
        PD_LAST_SEARCH_REASON="invalid_topology"
        return 1
    fi

    if [ "${PD_LEASE_MAX_AGE:-0}" -gt 0 ] 2>/dev/null; then
        python3 "$curr_dir/host_role_lease.py" prune-stale --max-age "$PD_LEASE_MAX_AGE" \
            || echo "WARN: prune-stale failed (ignored)"
    fi

    echo "PD 模式: topology=$TOPOLOGY, 每实例卡数=$NPU_QUANTITY, 最少主机数=${needed}, same_role_colocate=$PD_ALLOW_SAME_ROLE_COLOCATE"

    local candidates=()
    local free_pairs=()
    for key in "${!npu_server_list[@]}"; do
        local host_ip="${npu_server_list[$key]}"
        local probe_out
        probe_out=$(ssh -q -o ConnectionAttempts=3 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 s_limingge@${host_ip} "
            source /home/s_limingge/npu_lock_manager_for_ci.sh
            TARGET_FREE_GPUS=$NPU_QUANTITY
            GPU_INFO=(\$(npu-smi info | grep \"No\ running\ processes\ found\ in\ NPU\" | awk '{print \$8}'))
            FREE_COUNT=\$(echo \"\${GPU_INFO[@]}\" | wc -w)
            echo \"PROBE ${key} free=\$FREE_COUNT\"
            if [ \"\$FREE_COUNT\" -lt \"\$TARGET_FREE_GPUS\" ]; then
                echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                exit 1
            fi
            TASK_ID=\"${TEST_TYPE}Test_${MODEL}_${JOB_COUNT}\"
            LOCAL_IP=\$(hostname -I | xargs printf \"%s\\n\" | grep \"10.0.0\")
            SERVER_NAME=\$(echo \$LOCAL_IP | sed 's/\./_/g')
            check_npu_locks_batch \${SERVER_NAME} \"\${GPU_INFO[*]}\" \${TASK_ID} ${SESSION_ID} NPU_LIST_FOUND
            if [ \${#NPU_LIST_FOUND[@]} -ge \$TARGET_FREE_GPUS ]; then
                echo \"FREE_OK \$FREE_COUNT\"
                exit 0
            fi
            echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
            exit 1
        ") || true

        if echo "$probe_out" | grep -q "FREE_OK"; then
            local free_n
            free_n=$(echo "$probe_out" | awk '/FREE_OK/ {print $2; exit}')
            free_n=${free_n:-$NPU_QUANTITY}
            echo "PD 候选机可用: $key => $host_ip (free_gpus≈$free_n)"
            candidates+=("$host_ip")
            free_pairs+=("${host_ip}:${free_n}")
        else
            echo "PD 候选机不可用或空闲不足: $key => $host_ip"
        fi
    done

    if [ ${#candidates[@]} -lt "$needed" ]; then
        echo "PD 候选机不足: need>=$needed got=${#candidates[@]}"
        PD_LAST_SEARCH_REASON="insufficient_hosts"
        return 1
    fi

    local host_roles
    host_roles=$(python3 "$curr_dir/host_role_lease.py" dump-roles 2>/dev/null || true)
    echo "当前主机角色租约: ${host_roles:-<empty>}"

    local cand_csv free_csv place_args
    cand_csv=$(IFS=,; echo "${candidates[*]}")
    free_csv=$(IFS=,; echo "${free_pairs[*]}")
    place_args=(
        --topology "$TOPOLOGY"
        --candidates "$cand_csv"
        --gpus-per-instance "$NPU_QUANTITY"
        --host-free-gpus "$free_csv"
        --shell
    )
    if [ -n "$host_roles" ]; then
        place_args+=(--host-roles "$host_roles")
    fi
    if [ "$PD_ALLOW_SAME_ROLE_COLOCATE" != "1" ]; then
        place_args+=(--no-same-role-colocate)
    fi

    local placed
    if ! placed=$(python3 "$curr_dir/pd_place_servers.py" "${place_args[@]}" 2>/tmp/pd_place_err.$$); then
        cat /tmp/pd_place_err.$$ >&2 || true
        if grep -qi "role starvation\|Cannot place" /tmp/pd_place_err.$$ 2>/dev/null; then
            PD_LAST_SEARCH_REASON="role_starvation"
            echo "WARN: PD 角色失衡或对端角色无可用主机（卡可能空闲但角色租约冲突）。"
            echo "      请检查: python3 $curr_dir/host_role_lease.py status"
            echo "      或等待对端角色/idle 释放；必要时: prune-stale / release-session"
        else
            PD_LAST_SEARCH_REASON="place_failed"
        fi
        rm -f /tmp/pd_place_err.$$
        return 1
    fi
    cat /tmp/pd_place_err.$$ >&2 || true
    rm -f /tmp/pd_place_err.$$

    # Acquire host role leases before committing placement
    local acquired_leases=()
    IFS=',' read -ra _ents <<< "$placed"
    local ent h role iid lease_id
    for ent in "${_ents[@]}"; do
        h="${ent%%:*}"
        rest="${ent#*:}"
        role="${rest%%:*}"
        iid="${rest##*:}"
        lease_id="${SESSION_ID}:${JOB_COUNT}:${iid}"
        if ! python3 "$curr_dir/host_role_lease.py" acquire \
            --host "$h" --role "$role" --lease-id "$lease_id" --session "$SESSION_ID"; then
            echo "ERROR: acquire host role failed for $ent; rolling back leases"
            for lid in "${acquired_leases[@]:-}"; do
                python3 "$curr_dir/host_role_lease.py" release --lease-id "$lid" || true
            done
            PD_LAST_SEARCH_REASON="acquire_failed"
            return 1
        fi
        acquired_leases+=("$lease_id")
    done

    placement_out="$placed"
    servers_found=()
    for ent in "${_ents[@]}"; do
        h="${ent%%:*}"
        local seen=0
        for s in "${servers_found[@]:-}"; do
            if [ "$s" = "$h" ]; then seen=1; break; fi
        done
        if [ "$seen" -eq 0 ]; then
            servers_found+=("$h")
        fi
    done

    echo "PD 放置结果: $placement_out"
    python3 "$curr_dir/pd_place_servers.py" --validate-placement "$placement_out" || {
        python3 "$curr_dir/host_role_lease.py" release-session --session "$SESSION_ID" || true
        PD_LAST_SEARCH_REASON="validate_failed"
        return 1
    }
    PD_LAST_SEARCH_REASON=""
    return 0
}

for name in "${!npu_server_list[@]}"; do
    echo "$name => ${npu_server_list[$name]}"
    if [ $name == 'aicc002' ]; then
        sshpass -p 's_limingge' scp "${curr_dir}/${ENGINE_TYPE}_job_executor_for_${TEST_TYPE}Test.sh" s_limingge@${npu_server_list['aicc002']}:/home/s_limingge
        sshpass -p 's_limingge' scp "${curr_dir}/npu_lock_manager_for_ci.sh" s_limingge@${npu_server_list['aicc002']}:/home/s_limingge
        if [ -f "${curr_dir}/pd_ascend_send_kvcache_compat.py" ]; then
            sshpass -p 's_limingge' scp "${curr_dir}/pd_ascend_send_kvcache_compat.py" s_limingge@${npu_server_list['aicc002']}:/home/s_limingge
        fi
    else
        scp "${curr_dir}/${ENGINE_TYPE}_job_executor_for_${TEST_TYPE}Test.sh" s_limingge@${npu_server_list[$name]}:/home/s_limingge
        scp "${curr_dir}/npu_lock_manager_for_ci.sh" s_limingge@${npu_server_list[$name]}:/home/s_limingge
        if [ -f "${curr_dir}/pd_ascend_send_kvcache_compat.py" ]; then
            scp "${curr_dir}/pd_ascend_send_kvcache_compat.py" s_limingge@${npu_server_list[$name]}:/home/s_limingge
        fi
    fi
done

GPU_resource_demand=()

for item in "${full_model_list[@]}"; do
    model=`echo "$item" | awk -F : '{print $1}'`
    found=0
    # for option in 'DynamicSplitFuseV2' 'PrefillFirst'; do
    for option in 'DynamicSplitFuseV2'; do
        use_prefix_cache_flag=-1
        for ((i=1; i<=${num_of_prefix_cache_options}; i=i+1)); do
            swap_space=0
            for ((j=1; j<=1; j=j+1)); do
                # 模型已经测试过了，检查下一个
                if [ $use_prefix_cache_flag -gt 0 ]; then
                    if [ $swap_space -eq 0 ]; then
                        if [ ! -z `cat ${processed_models} | grep -w ${model}_${option}_use-prefix-cache` ]; then
                            swap_space=40
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
                            swap_space=40
                            continue
                        fi
                    else
                        if [ ! -z `cat ${processed_models} | grep -w ${model}_${option}_swap-space` ]; then
                            continue
                        fi
                    fi
                fi
                GPU_resource_demand+=(${item})
                found=1
                break
            done
            if [ $found -eq 1 ]; then
                break
            fi
            use_prefix_cache_flag=$((-use_prefix_cache_flag))
        done
        if [ $found -eq 1 ]; then
            break
        fi
    done
done

GPU_resource_demand=($(printf "%s\n" "${GPU_resource_demand[@]}" | uniq))

echo "开始测试模型列表：${GPU_resource_demand[@]}"

if [ -z $version ]; then
    echo "推理引擎版本: Latest"
else
    echo "推理引擎版本: ${version}"
fi

ret=0

while true; do
    job_count=0
    temp_list=()
    unset pid_map
    declare -A pid_map
    for item in "${GPU_resource_demand[@]}"; do
        model=`echo "$item" | awk -F : '{print $1}'`
        GPU_QUANTITY=`echo "$item" | awk -F : '{print $2}'`
        echo "当前模型: $model, GPU数量: $GPU_QUANTITY"
        if [ -n "$PD_TOPOLOGY" ]; then
            if search_pd_servers $model $job_count $GPU_QUANTITY "$PD_TOPOLOGY" servers PD_PLACEMENT; then
                SERVER_QUANTITY=${#servers[@]}
                export PD_PLACEMENT
                export PD_TOPOLOGY
                PD_SEARCH_FAIL_ROUNDS=0
            else
                servers=()
                SERVER_QUANTITY=1
                PD_PLACEMENT=""
                PD_SEARCH_FAIL_ROUNDS=$((PD_SEARCH_FAIL_ROUNDS + 1))
                echo "PD 选机失败 (${PD_LAST_SEARCH_REASON:-unknown}), round=${PD_SEARCH_FAIL_ROUNDS}/${PD_SEARCH_MAX_ROUNDS:-unlimited}"
                if [ "${PD_SEARCH_MAX_ROUNDS:-0}" -gt 0 ] && [ "$PD_SEARCH_FAIL_ROUNDS" -ge "$PD_SEARCH_MAX_ROUNDS" ]; then
                    echo "ERROR: PD 选机连续失败已达上限 (${PD_SEARCH_MAX_ROUNDS})，跳过模型 ${model}（避免无限空等）"
                    ret=1
                    PD_SEARCH_FAIL_ROUNDS=0
                    continue
                fi
            fi
        else
            PD_PLACEMENT=""
            search_servers $model $job_count $GPU_QUANTITY servers
        fi
        if [ ${#servers[@]} -ge ${SERVER_QUANTITY} ] && [ ${#servers[@]} -gt 0 ]; then
            echo "已找到满足条件的空闲 GPU, 开始测试模型${model}......"
            if [ -n "$PD_PLACEMENT" ]; then
                echo "PD_PLACEMENT=$PD_PLACEMENT"
            fi
            echo
            if [ $TEST_TYPE == "Stability" ]; then
                PD_TOPOLOGY="$PD_TOPOLOGY" PD_PLACEMENT="$PD_PLACEMENT" \
                $curr_dir/siginfer_ascend_test.sh 0 "${servers[*]}" ${model} ${job_count} ${TEST_TYPE} ${ENGINE_TYPE} ${SESSION_ID} ${version} > $curr_dir/logs/stability/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log 2>&1 &
                last_pid=$!
                pid_map[$last_pid]=$item
                status_msg=`tail -F $curr_dir/logs/stability/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log | grep --line-buffered -m 1 -E "开始执行模型Stability测试任务|测试全部完成"`
            elif [ $TEST_TYPE == "Performance" ]; then
                PD_TOPOLOGY="$PD_TOPOLOGY" PD_PLACEMENT="$PD_PLACEMENT" \
                $curr_dir/siginfer_ascend_test.sh 1 "${servers[*]}" ${model} ${job_count} ${TEST_TYPE} ${ENGINE_TYPE} ${SESSION_ID} ${TEST_PARAM} ${version} > $curr_dir/logs/performance/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log 2>&1 &
                last_pid=$!
                pid_map[$last_pid]=$item
                status_msg=`tail -F $curr_dir/logs/performance/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log | grep --line-buffered -m 1 -E "开始执行模型Performance测试任务|测试全部完成"`
            elif [ $TEST_TYPE == "Smoke" ]; then
                PD_TOPOLOGY="$PD_TOPOLOGY" PD_PLACEMENT="$PD_PLACEMENT" \
                $curr_dir/siginfer_ascend_test.sh 1 "${servers[*]}" ${model} ${job_count} ${TEST_TYPE} ${ENGINE_TYPE} ${SESSION_ID} ${version} > $curr_dir/logs/smoke/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log 2>&1 &
                last_pid=$!
                pid_map[$last_pid]=$item
                status_msg=`tail -F $curr_dir/logs/smoke/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log | grep --line-buffered -m 1 -E "开始执行模型Smoke测试任务|测试全部完成"`
            elif [ $TEST_TYPE == "Accuracy" ]; then
                PD_TOPOLOGY="$PD_TOPOLOGY" PD_PLACEMENT="$PD_PLACEMENT" \
                $curr_dir/siginfer_ascend_test.sh 0 "${servers[*]}" ${model} ${job_count} ${TEST_TYPE} ${ENGINE_TYPE} ${SESSION_ID} ${version} > $curr_dir/logs/accuracy/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log 2>&1 &
                last_pid=$!
                pid_map[$last_pid]=$item
                status_msg=`tail -F $curr_dir/logs/accuracy/$SESSION_ID/cron_job_${log_name_suffix}_${job_count}.log | grep --line-buffered -m 1 -E "开始执行模型Accuracy测试任务|测试全部完成"`
            else
                echo "测试类型错误！"
                exit 1
            fi

            if [ $status_msg == "测试全部完成！" ]; then
                echo "模型运行环境配置失败，准备尝试测试下一个模型......"
                echo
                wait $last_pid  # 等待上一个子进程结束
                err=$?          # 保存上一个结束子进程的退出状态
                if [ $err -ne 0 ]; then
                    if [ $err -eq 10 ]; then  # 没有资源，等待超时
                        echo "没有资源，等待超时，加入队列，稍后重试......"
                        temp_list+=(${pid_map[$last_pid]})  # 加入队列，稍后重试
                        continue
                    fi
                else
                    echo "程序出错！"
                fi
                ret=1
                continue
            else
                echo $status_msg
            fi

            ((job_count++))
            if [ $job_count -ge $parallel ]; then
                # 等待所有后台子任务结束
                remaining=$job_count
                while (( remaining > 0 )); do
                    wait -n -p done_pid  # 等待任意一个子进程结束
                    err=$?               # 保存最先结束子进程的退出状态
                    if [ $err -ne 0 ]; then
                        if [ $err -eq 10 ]; then  # 没有资源，等待超时
                            temp_list+=(${pid_map[$done_pid]})  # 加入队列，稍后重试
                        fi
                    fi
                    ((remaining--))
                done

                job_count=0
                echo "当前批量模型测试完成！"
                echo
            fi
        else
            temp_list+=(${item})
            if [ -n "$PD_TOPOLOGY" ]; then
                echo "PD 暂无法放置模型${model} (reason=${PD_LAST_SEARCH_REASON:-unknown})，稍后重试......"
            else
                echo "未找到足够的空闲 GPU, 无法测试模型${model}, 准备尝试测试下一个模型......"
            fi
            echo
            sleep "${PD_SEARCH_RETRY_SEC:-10}"
        fi
    done

    if [ $job_count -gt 0 ] && [ $job_count -lt $parallel ]; then
        # 等待所有后台子任务结束
        remaining=$job_count
        while (( remaining > 0 )); do
            wait -n -p done_pid  # 等待任意一个子进程结束
            err=$?               # 保存最先结束子进程的退出状态
            if [ $err -ne 0 ]; then
                if [ $err -eq 10 ]; then  # 没有资源，等待超时
                    temp_list+=(${pid_map[$done_pid]})  # 加入队列，稍后重试
                fi
            fi
            ((remaining--))
        done

        echo "当前批量模型测试完成！"
        echo
    fi

    if [[ ${#temp_list[@]} -eq 0 ]]; then
        echo "全部测试完成！"
        if [ $TEST_TYPE == "Accuracy" ]; then
            python3 $curr_dir/write_file.py --file "$curr_dir/report_${log_name_suffix}/$SESSION_ID/${log_name_suffix}_result.txt" --framework Ascend_910B1 --engine ${ENGINE_TYPE} --sessionID ${SESSION_ID}
        elif [ $TEST_TYPE == "Smoke" ]; then
            if [ -f $curr_dir/report_${log_name_suffix}/$SESSION_ID/version.txt ]; then
                latest_tag=$(cat $curr_dir/report_${log_name_suffix}/$SESSION_ID/version.txt)
            else
                latest_tag="unknown"
            fi
            
            python3 $curr_dir/SendMsgToBot.py "$latest_tag" "$curr_dir/report_${log_name_suffix}/$SESSION_ID/summary_${log_name_suffix}.txt"

            last_date=$(date -d "$log_name_suffix -1 day" +"%Y%m%d")
            if [ -f $curr_dir/report_${last_date}/$SESSION_ID/version.txt ]; then
                last_version=$(cat $curr_dir/report_${last_date}/$SESSION_ID/version.txt)
            else
                last_version="unknown"
            fi
            
            if [ -f "$curr_dir/report_${last_date}/$SESSION_ID/summary_${last_date}.txt" ]; then
                console_output_flag=1
                if [ $console_output_flag -eq 1 ]; then
                    python3 -c "from SendMsgToBot import compare_summary_files; result = compare_summary_files(\"$latest_tag\", \"$curr_dir/report_${log_name_suffix}/$SESSION_ID/summary_${log_name_suffix}.txt\", \"$last_version\", \"$curr_dir/report_${last_date}/$SESSION_ID/summary_${last_date}.txt\"); print(result)"
                else
                    python3 -c "from SendMsgToBot import compare_summary_files, send_summary_to_server; result = compare_summary_files(\"$latest_tag\", \"$curr_dir/report_${log_name_suffix}/$SESSION_ID/summary_${log_name_suffix}.txt\", \"$last_version\", \"$curr_dir/report_${last_date}/$SESSION_ID/summary_${last_date}.txt\"); send_summary_to_server(None, None, result)"
                fi
            fi
        fi
        break
    else
        GPU_resource_demand=("${temp_list[@]}")
        echo
        echo "准备尝试进行下一轮模型测试: ${GPU_resource_demand[@]}"
        echo
    fi
done

exit $ret
