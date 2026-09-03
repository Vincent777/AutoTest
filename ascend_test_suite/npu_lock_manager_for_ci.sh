#!/bin/bash

# NPU锁管理器
# 用于在分布式环境中管理NPU资源的互斥访问

# 锁文件存储目录（使用共享目录，确保所有服务器都能访问）
LOCK_DIR="/home/s_limingge/.npu_locks"

# 创建锁目录（如果不存在）
mkdir -p "$LOCK_DIR"

# 锁的超时时间（秒）- 防止死锁
LOCK_TIMEOUT=86400  # 24小时

# 是否启用超时检查(0: 不启用, 1: 启用)，默认不启用
ENABLE_TIMEOUT_CHECK=0

# 生成锁目录名（使用目录而不是文件）
# 参数: $1=服务器名或IP, $2=NPU索引
get_lock_file() {
    local server=$1
    local npu_id=$2
    echo "${LOCK_DIR}/${server}_npu_${npu_id}.lock"
}

# 尝试获取NPU锁
# 参数: $1=服务器名或IP, $2=NPU索引, $3=任务ID（用于标识哪个任务持有锁）, $4=SessionID
# 返回: 0=成功获取锁, 1=锁已被占用
acquire_npu_lock() {
    local server=$1
    local npu_id=$2
    local task_id=$3
    local session_id=$4
    local lock_dir=$(get_lock_file "$server" "$npu_id")
    
    # 使用 mkdir 的原子性来创建锁目录
    # mkdir 失败说明目录已存在（被其他进程锁定）
    if mkdir "$lock_dir" 2>/dev/null; then
        # 成功创建锁目录，写入锁信息
        cat > "${lock_dir}/info" << EOF
task_id=$task_id
timestamp=$(date +%s)
session_id=$session_id
hostname=$(hostname)
EOF
        return 0
    else
        # 如果task_id相同，则复用已经存在的锁
        if [ ! -z "$task_id" ] && [ -d "$lock_dir" ] && [ -f "${lock_dir}/info" ]; then
            local lock_task_id=$(grep "^task_id=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
            local lock_session_id=$(grep "^session_id=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
            if [ "$lock_task_id" == "$task_id" ] && [ "$lock_session_id" == "$session_id" ]; then
                echo "锁已存在，复用锁: ${server} NPU ${npu_id}, ${lock_task_id} == ${task_id}, ${lock_session_id} == ${session_id}" >&2
                return 0
            fi
        fi

        # 锁已被占用，检查是否超时
        if [ $ENABLE_TIMEOUT_CHECK -eq 1 ] && [ -d "$lock_dir" ] && [ -f "${lock_dir}/info" ]; then
            local lock_timestamp=$(grep "^timestamp=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
            if [ ! -z "$lock_timestamp" ]; then
                local current_time=$(date +%s)
                local elapsed=$((current_time - lock_timestamp))
                
                # 如果锁超时，强制释放并重新获取
                if [ $elapsed -ge $LOCK_TIMEOUT ]; then
                    echo "警告: NPU锁超时 (${server} NPU ${npu_id}), 强制释放" >&2
                    rm -rf "$lock_dir"
                    # 递归调用重新获取锁
                    acquire_npu_lock "$server" "$npu_id" "$task_id" "$session_id"
                    return $?
                fi
            fi
        fi

        return 1
    fi
}

# 批量获取NPU锁（原子操作 - 要么全部成功，要么全部失败）
# 参数: $1=服务器名或IP, $2=NPU索引列表（空格分隔）, $3=所需数量, $4=任务ID, $5=SessionID, $6=返回结果
# 返回: 0=成功, 1=失败
acquire_npu_locks_batch() {
    local server=$1
    local npu_list=$2
    local acquired_count=$3
    local task_id=$4
    local session_id=$5
    local -n acquired_locks=$6     # 传名引用

    # 尝试获取所需数量的锁
    acquired_locks=()
    for npu_id in $npu_list; do
        if acquire_npu_lock "$server" "$npu_id" "$task_id" "$session_id"; then
            acquired_locks+=("$npu_id")
            if [ ${#acquired_locks[@]} -eq $acquired_count ]; then
                return 0
            fi
        fi
    done
    
    # 如果没有全部成功，释放已获取的锁
    for npu_id in "${acquired_locks[@]}"; do
        release_npu_lock "$server" "$npu_id" "$task_id" "$session_id"
    done
    
    return 1
}

# 释放NPU锁
# 参数: $1=服务器名或IP, $2=NPU索引, $3=任务ID（可选，用于验证）, $4=SessionID
release_npu_lock() {
    local server=$1
    local npu_id=$2
    local task_id=$3
    local session_id=$4
    local lock_dir=$(get_lock_file "$server" "$npu_id")
    
    # 如果提供了task_id，验证锁是否属于当前任务
    if [ ! -z "$task_id" ] && [ -d "$lock_dir" ] && [ -f "${lock_dir}/info" ]; then
        local lock_task_id=$(grep "^task_id=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
        local lock_session_id=$(grep "^session_id=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
        if [ "$lock_task_id" != "$task_id" ] || [ "$lock_session_id" != "$session_id" ]; then
            echo "警告: 尝试释放不属于当前任务的锁 (${server} NPU ${npu_id}), ${lock_task_id} != ${task_id} 或者 ${lock_session_id} != ${session_id}" >&2
            return 1
        fi
    fi
    
    # 删除锁目录即可释放锁
    rm -rf "$lock_dir"
    return 0
}

# 批量释放NPU锁
# 参数: $1=服务器名或IP, $2=NPU索引列表（空格分隔）, $3=任务ID，$4=SessionID
release_npu_locks_batch() {
    local server=$1
    local npu_list=$2
    local task_id=$3
    local session_id=$4
    
    for npu_id in $npu_list; do
        release_npu_lock "$server" "$npu_id" "$task_id" "$session_id"
    done
}

# 检查NPU锁状态
# 参数: $1=服务器名或IP, $2=NPU索引, $3=任务ID $4=SessionID
# 返回: 0=锁空闲, 1=锁被占用
check_npu_lock() {
    local server=$1
    local npu_id=$2
    local task_id=$3
    local session_id=$4
    local lock_dir=$(get_lock_file "$server" "$npu_id")
    
    # 简单检查目录是否存在
    if [ ! -d "$lock_dir" ]; then
        # 锁目录不存在，说明未被锁定
        return 0
    else
        # 如果task_id相同，则复用已经存在的锁
        if [ ! -z "$task_id" ] && [ -d "$lock_dir" ] && [ -f "${lock_dir}/info" ]; then
            local lock_task_id=$(grep "^task_id=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
            local lock_session_id=$(grep "^session_id=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
            if [ "$lock_task_id" == "$task_id" ] && [ "$lock_session_id" == "$session_id" ]; then
                echo "锁已存在，可以复用锁: ${server} NPU ${npu_id}, ${lock_task_id} == ${task_id}, ${lock_session_id} == ${session_id}" >&2
                return 0
            fi
        fi

        # 检查锁是否超时
        if [ $ENABLE_TIMEOUT_CHECK -eq 1 ] && [ -f "${lock_dir}/info" ]; then
            local lock_timestamp=$(grep "^timestamp=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
            if [ ! -z "$lock_timestamp" ]; then
                local current_time=$(date +%s)
                local elapsed=$((current_time - lock_timestamp))
                if [ $elapsed -ge $LOCK_TIMEOUT ]; then
                    # 超时，视为空闲
                    return 0
                fi
            fi
        fi

        # 锁被占用且未超时
        return 1
    fi
}

# 批量检查NPU锁
# 参数: $1=服务器名或IP, $2=NPU索引列表（空格分隔）, $3=任务ID, $4=SessionID, $5=返回结果
check_npu_locks_batch() {
    local server=$1
    local npu_list=$2
    local task_id=$3
    local session_id=$4
    local -n npu_list_found=$5     # 传名引用
    
    npu_list_found=()
    for npu_id in $npu_list; do
        if check_npu_lock "$server" "$npu_id" "$task_id" "$session_id"; then
            npu_list_found+=("$npu_id")
        fi
    done

    return 0
}

# 获取锁信息
# 参数: $1=服务器名或IP, $2=NPU索引
get_lock_info() {
    local server=$1
    local npu_id=$2
    local lock_dir=$(get_lock_file "$server" "$npu_id")
    
    if [ -d "$lock_dir" ] && [ -f "${lock_dir}/info" ]; then
        cat "${lock_dir}/info"
    else
        echo "Lock not found"
        return 1
    fi
}

# 列出所有锁
list_all_locks() {
    echo "=== 所有NPU锁状态 ==="
    for lock_dir in "$LOCK_DIR"/*.lock; do
        if [ -d "$lock_dir" ]; then
            local basename=$(basename "$lock_dir")
            echo "锁目录: $basename"
            if [ -f "${lock_dir}/info" ]; then
                cat "${lock_dir}/info"
            else
                echo "信息文件不存在"
            fi
            echo "---"
        fi
    done
}

# 清理所有锁（谨慎使用！）
cleanup_all_locks() {
    echo "警告: 正在清理所有NPU锁..."
    rm -rf "$LOCK_DIR"/*.lock
    echo "所有锁已清理完成"
}

# 清理超时的锁
cleanup_timeout_locks() {
    local current_time=$(date +%s)
    local cleaned_count=0
    
    if [ $ENABLE_TIMEOUT_CHECK -eq 0 ]; then
        echo "超时检查未启用, 跳过清理超时锁"
        return
    fi

    for lock_dir in "$LOCK_DIR"/*.lock; do
        if [ -d "$lock_dir" ]; then
            if [ -f "${lock_dir}/info" ]; then
                local lock_timestamp=$(grep "^timestamp=" "${lock_dir}/info" 2>/dev/null | cut -d= -f2)
                if [ ! -z "$lock_timestamp" ]; then
                    local elapsed=$((current_time - lock_timestamp))
                    if [ $elapsed -ge $LOCK_TIMEOUT ]; then
                        echo "清理超时锁: $(basename "$lock_dir") (超时 ${elapsed} 秒)"
                        rm -rf "$lock_dir"
                        ((cleaned_count++))
                    fi
                fi
            fi
        fi
    done
    
    echo "清理了 $cleaned_count 个超时锁"
}

# 获取空闲 NPU 的 Logic Device ID 列表（兼容 910B 单芯与 310P 一卡双芯）
#
# 背景:
#   - 910B(单芯): "No running processes found in NPU X" 的 X 即 Device ID。
#   - 310P(一卡双芯): 进程表打印物理卡 NPU ID（如 18944/19072）；一卡空闲时两芯都空闲。
#     部分驱动版本 Chip 行只有 Bus-Id、没有 Device 数字，不能把物理卡 ID 当作 Device。
#     此时按 Chip 行出现顺序分配全局 Logic Device ID (0,1,2,3,...)。
#
# 判定双芯/物理卡模式（满足其一即展开）:
#   1) 任一物理卡下 Chip 行数 >= 2
#   2) 空闲 NPU ID 中存在 > 64 的物理卡 ID
#
# 输出: 空格分隔、按数值升序的 Device ID，例如 "1 4 5" 或 "0 1 2 3"
# 用法: GPU_INFO=($(get_free_npu_device_ids))
get_free_npu_device_ids() {
    local smi_out
    smi_out=$(npu-smi info 2>/dev/null) || {
        echo "错误: 无法执行 npu-smi info" >&2
        return 1
    }

    # 优先用 npu-smi info -m（NPU ID / Chip ID / Device ID 三列），失败则解析 info 表格
    local map_out=""
    map_out=$(npu-smi info -m 2>/dev/null) || true

    echo "$smi_out" | MAP_OUT="$map_out" awk '
    BEGIN {
        current_npu = ""
        max_chips = 0
        in_process = 0
        nchips = 0
        next_logic = 0
        phy_free = 0
        has_map = 0
        map_out = ENVIRON["MAP_OUT"]

        # 解析 npu-smi info -m: 每行 NPU_ID Chip_ID Device_ID
        if (map_out != "") {
            n = split(map_out, lines, /\n/)
            for (li = 1; li <= n; li++) {
                line = lines[li]
                gsub(/\|/, " ", line)
                nn = split(line, a, /[[:space:]]+/)
                nf = 0
                delete f
                for (i = 1; i <= nn; i++) if (a[i] != "") f[++nf] = a[i]
                if (nf >= 3 && f[1] ~ /^[0-9]+$/ && f[2] ~ /^[0-9]+$/ && f[3] ~ /^[0-9]+$/) {
                    devices[f[1]] = devices[f[1]] " " f[3]
                    chip_count[f[1]]++
                    if (chip_count[f[1]] > max_chips) max_chips = chip_count[f[1]]
                    has_map = 1
                }
            }
        }
    }
    /Processes:/ { in_process = 1 }
    /No running processes found in NPU/ {
        for (i = NF; i >= 1; i--) {
            t = $i
            gsub(/\|/, "", t)
            if (t ~ /^[0-9]+$/) {
                free[t] = 1
                if ((t + 0) > 64) phy_free = 1
                break
            }
        }
        next
    }
    {
        if (in_process || has_map) next

        line = $0
        gsub(/\|/, " ", line)
        n = split(line, a, /[[:space:]]+/)
        nf = 0
        delete f
        for (i = 1; i <= n; i++) if (a[i] != "") f[++nf] = a[i]
        if (nf < 2) next
        if (f[1] ~ /^(NPU|Chip|Process|No|=|\+|Version)/) next
        if (f[1] !~ /^[0-9]+$/) next

        # 卡头行，兼容多种 310P/910B 表格:
        #   18944 310P3 OK ... | 0 910B1 OK ... | 18944 OK ... | 18944 0 OK ...
        is_header = 0
        if (f[2] ~ /[A-Za-z]/ && f[2] !~ /^[0-9a-fA-F]+:/) {
            # 第二列是产品名或 Health(OK)
            is_header = 1
        } else if (nf >= 3 && f[2] ~ /^[0-9]+$/ && f[3] ~ /^(OK|Warning|Error|Failure)/) {
            # 第二列 Chip-Phy-ID，第三列 Health
            is_header = 1
        }
        if (is_header) {
            current_npu = f[1]
            if (!(current_npu in chip_count)) chip_count[current_npu] = 0
            next
        }

        if (current_npu == "") next

        # 芯行: Chip [Device] Bus-Id ...
        if (f[2] ~ /^[0-9]+$/ && nf >= 3 && f[3] ~ /:/) {
            # Chip Device Bus-Id
            chip_dev = f[2] + 0
            chip_count[current_npu]++
            if (chip_count[current_npu] > max_chips) max_chips = chip_count[current_npu]
            nchips++
            chip_npu[nchips] = current_npu
            chip_devcol[nchips] = chip_dev
            chip_has_devcol[nchips] = 1
        } else if (f[2] ~ /:/) {
            # Chip Bus-Id（无 Device 列，310P 常见）
            chip_count[current_npu]++
            if (chip_count[current_npu] > max_chips) max_chips = chip_count[current_npu]
            nchips++
            chip_npu[nchips] = current_npu
            chip_devcol[nchips] = -1
            chip_has_devcol[nchips] = 0
        }
    }
    END {
        # 若未走 info -m，根据 Chip 行生成 NPU -> Device 映射
        if (!has_map && nchips > 0) {
            dual = (max_chips >= 2 || phy_free) ? 1 : 0
            if (dual) {
                # 若 Device 列存在且同一卡上不全是相同值，直接用 Device 列；
                # 否则（无 Device 列 / 仅卡内索引）按出现顺序分配 0,1,2,...
                use_devcol = 1
                for (npu in chip_count) {
                    if (chip_count[npu] < 1) continue
                    seen_val = ""
                    uniq = 0
                    for (i = 1; i <= nchips; i++) {
                        if (chip_npu[i] != npu) continue
                        if (!chip_has_devcol[i]) { use_devcol = 0; break }
                        if (seen_val == "") { seen_val = chip_devcol[i]; uniq = 1 }
                        else if (chip_devcol[i] != seen_val) uniq++
                    }
                    if (!use_devcol) break
                    # 双芯卡但 Device 列全相同（如都是 0）→ 不可用
                    if (chip_count[npu] >= 2 && uniq < 2) { use_devcol = 0; break }
                }
                for (i = 1; i <= nchips; i++) {
                    npu = chip_npu[i]
                    if (use_devcol) {
                        dev = chip_devcol[i]
                    } else {
                        dev = next_logic++
                    }
                    devices[npu] = devices[npu] " " dev
                }
            } else {
                # 单芯: Device = NPU ID
                for (i = 1; i <= nchips; i++) {
                    npu = chip_npu[i]
                    devices[npu] = devices[npu] " " npu
                }
            }
        }

        dual_chip = (max_chips >= 2 || phy_free) ? 1 : 0
        delete seen
        nout = 0
        for (npu in free) {
            if (dual_chip && (npu in devices)) {
                n = split(devices[npu], d, " ")
                for (i = 1; i <= n; i++) {
                    if (d[i] == "" || d[i] in seen) continue
                    seen[d[i]] = 1
                    out[++nout] = d[i] + 0
                }
            } else {
                if (!(npu in seen)) {
                    seen[npu] = 1
                    out[++nout] = npu + 0
                }
            }
        }
        for (i = 1; i <= nout; i++) {
            for (j = i + 1; j <= nout; j++) {
                if (out[j] < out[i]) {
                    t = out[i]; out[i] = out[j]; out[j] = t
                }
            }
        }
        for (i = 1; i <= nout; i++) {
            printf "%s%s", out[i], (i < nout ? " " : "")
        }
        if (nout > 0) printf "\n"
    }'
}

# 主函数 - 用于命令行调用
main() {
    local command=$1
    shift
    
    case "$command" in
        acquire)
            if [ $# -lt 3 ]; then
                echo "用法: $0 acquire <server> <npu_id> <task_id> <session_id>"
                exit 1
            fi
            acquire_npu_lock "$1" "$2" "$3" "$4"
            ;;
        acquire_batch)
            if [ $# -lt 3 ]; then
                echo "用法: $0 acquire_batch <server> '<npu_list>' <task_id> <session_id>"
                exit 1
            fi
            acquire_npu_locks_batch "$1" "$2" "$3" "$4"
            ;;
        release)
            if [ $# -lt 2 ]; then
                echo "用法: $0 release <server> <npu_id> <task_id> <session_id>"
                exit 1
            fi
            release_npu_lock "$1" "$2" "$3" "$4"
            ;;
        release_batch)
            if [ $# -lt 3 ]; then
                echo "用法: $0 release_batch <server> '<npu_list>' <task_id> <session_id>"
                exit 1
            fi
            release_npu_locks_batch "$1" "$2" "$3" "$4"
            ;;
        check)
            if [ $# -lt 2 ]; then
                echo "用法: $0 check <server> <npu_id>"
                exit 1
            fi
            check_npu_lock "$1" "$2"
            ;;
        info)
            if [ $# -lt 2 ]; then
                echo "用法: $0 info <server> <npu_id>"
                exit 1
            fi
            get_lock_info "$1" "$2"
            ;;
        list)
            list_all_locks
            ;;
        cleanup_all)
            cleanup_all_locks
            ;;
        cleanup_timeout)
            cleanup_timeout_locks
            ;;
        list-free)
            get_free_npu_device_ids
            ;;
        *)
            echo "用法: $0 {acquire|acquire_batch|release|release_batch|check|info|list|list-free|cleanup_all|cleanup_timeout} [args...]"
            exit 1
            ;;
    esac
}

# 如果直接执行此脚本（而非source）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

