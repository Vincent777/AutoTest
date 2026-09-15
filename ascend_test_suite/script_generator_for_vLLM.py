from openpyxl import load_workbook
import re
import os
import sys

# 默认 CI 镜像（与 job_executor_template_for_vLLM.sh 一致）
DEFAULT_VLLM_IMAGE_RE = re.compile(
    r"quay\.io/ascend/vllm-ascend:\S+|docker\.xcoresigma\.com/docker/vllm/vllm-openai:\S+"
)

# Excel 中可能出现的镜像名（含短名 sd-vllm-ascend:tag）
DOCKER_IMAGE_RE = re.compile(
    r"("
    r"docker\.xcoresigma\.com/docker/[^\s]+|"
    r"quay\.io/ascend/[^\s]+|"
    r"sd-vllm-ascend:[^\s]+|"
    r"vllm-ascend:[^\s]+"
    r")"
)


def strip_existing_pd_flags(args: str) -> str:
    """Excel 合部命令里若已手写 PD 参数，去掉以免和 $PD_EXTRA_ARGS 重复。"""
    result = re.sub(r"--kv-transfer-config\s+'[^']*'", "", args)
    result = re.sub(r'--kv-transfer-config\s+"[^"]*"', "", result)
    result = re.sub(r"--kv-transfer-config\s+\S+", "", result)
    return re.sub(r"\s+", " ", result).strip()


def extract_docker_image(args: str):
    """从 Excel docker run 命令中提取镜像名；没有则返回 None。"""
    match = DOCKER_IMAGE_RE.search(args or "")
    return match.group(1) if match else None


def strip_docker_prefix(args: str) -> str:
    """去掉 docker run ... IMAGE，只保留容器内启动命令/参数。"""
    match = DOCKER_IMAGE_RE.search(args or "")
    if match:
        return args[match.end() :].strip()
    # 兜底：旧逻辑，兼容仅含 vllm-openai 的写法
    result = re.sub(r"^.*docker\.xcoresigma\.com/docker/vllm/vllm-openai\:\S+", "", args)
    return result.strip()


def is_custom_entrypoint(cmd: str) -> bool:
    """启动入口是脚本/绝对路径，而不是 vllm serve 参数列表。"""
    cmd = (cmd or "").strip()
    if not cmd:
        return False
    if re.match(r"vllm\s+serve\b", cmd):
        return False
    # /workspace/cmd/serve.sh、/home/.../start_xxx.sh、bash xxx.sh
    if re.search(r"\.sh\b", cmd):
        return True
    if cmd.startswith("/") and not cmd.startswith("--"):
        return True
    return False


def normalize_vllm_args(name: str, args: str):
    """
    返回 (image_or_None, launch_cmd, is_custom_entrypoint)。
    image_or_None: 仅当 Excel 指定了非默认镜像时返回镜像名，否则 None（用 CI VERSION tag）。
    """
    args = (args or "").split("\n")[0]
    image = extract_docker_image(args)
    result = strip_docker_prefix(args)

    # 默认镜像不写入覆盖；自定义镜像（如 sd-vllm-ascend:...）需要覆盖
    custom_image = None
    if image and not DEFAULT_VLLM_IMAGE_RE.fullmatch(image):
        # quay / xcoresigma 官方前缀也可能带固定 tag，仍视为“用 CI VERSION”时 image 会被剥掉
        # 这里：只要不是「由 LATEST_TAG 驱动的默认仓库镜像」，就保留 Excel 镜像
        if not image.startswith("quay.io/ascend/vllm-ascend:") and not image.startswith(
            "docker.xcoresigma.com/docker/vllm/vllm-openai:"
        ):
            custom_image = image
        # Excel 里写死的 quay tag 也忽略，继续用 $LATEST_TAG

    if is_custom_entrypoint(result):
        # 自定义启动脚本：保留原命令，不强行包一层 vllm serve / --served-model-name
        result = strip_existing_pd_flags(result)
        # 若脚本本身未声明 port，注入 PORT 环境变量供脚本读取（不改脚本参数）
        if not re.search(r"--port\s+", result):
            result = f"env PORT=$PORT {result}"
        return custom_image, re.sub(r"\s+", " ", result).strip(), True

    # 标准 vllm serve 参数路径
    result = re.sub(r"--model\s+", "", result)
    result = re.sub(r"--port\s+\d+", "--port $PORT", result)
    if not re.search(r"--port\s+\$PORT\b|--port\s+\d+", result):
        result = f"{result} --port $PORT"
    result = re.sub(r"--served-model-name\s+\S+", f"--served-model-name {name}", result)
    result = strip_existing_pd_flags(result)
    return custom_image, re.sub(r"\s+", " ", result).strip(), False


def main():
    if len(sys.argv) != 3:
        print("Usage: python script_generator <test_type> <version>")
        sys.exit(1)

    test_type = sys.argv[1]
    version = sys.argv[2]

    curr_dir = os.getcwd()

    # 加载 Excel 文件
    file_path = f"{curr_dir}/{version}/vLLM_model_list.xlsx"
    workbook = load_workbook(file_path)

    # 选择工作表
    sheet = workbook["Ascend"]

    # 获取行数
    row_count = sheet.max_row
    print(f"总行数: {row_count}")

    target_file = ""
    src_code = ""

    if test_type == "Smoke":
        target_file = "vLLM_job_executor_for_SmokeTest.sh"
    elif test_type == "Performance":
        target_file = "vLLM_job_executor_for_PerformanceTest.sh"
    elif test_type == "Stability":
        target_file = "vLLM_job_executor_for_StabilityTest.sh"
    elif test_type == "Accuracy":
        target_file = "vLLM_job_executor_for_AccuracyTest.sh"

    start = True
    for row in sheet.iter_rows(min_row=2, max_row=row_count, values_only=True):
        name = row[0]
        if not name:
            continue
        args = row[2]
        custom_image, result, custom_entry = normalize_vllm_args(name, args)

        if start:
            src_code += f'if [ $MODEL == "{name}" ]; then\n'
            start = False
        else:
            src_code += f'elif [ $MODEL == "{name}" ]; then\n'

        if custom_image:
            src_code += f'    VLLM_DOCKER_IMAGE="{custom_image}"\n'

        if custom_entry:
            # 自定义入口可能含 sed; cmd 等多条命令，需 bash -c 才能作为容器 CMD
            src_code += f'    echo "{result}"\n'
            src_code += f'    EXEC_COMMAND+=" bash -c \\"{result}\\" > $LOG_NAME 2>&1 &"\n'
        else:
            src_code += '    echo "vllm serve '
            src_code += result
            src_code += ' $PD_EXTRA_ARGS"\n'
            # 容器内先按需安装 triton，再 exec vllm（& 必须在 docker run 外侧，否则 bash -c 退出导致容器 Exit）
            src_code += '    EXEC_COMMAND+=" bash -c \\"${VLLM_TRITON_BOOTSTRAP}; exec vllm serve '
            src_code += result
            src_code += ' $PD_EXTRA_ARGS\\" > $LOG_NAME 2>&1 &"\n'

    src_code += "fi\n"

    template_file = "job_executor_template_for_vLLM.sh"

    try:
        with open(f"{curr_dir}/{template_file}", "r", encoding="utf-8") as file:
            lines = file.readlines()

        line_num = 0
        for line in lines:
            if "<<<generated source code>>>" in line:
                lines[line_num] = src_code
                with open(f"{curr_dir}/{target_file}", "w") as file:
                    file.write("".join(lines))
                break
            elif "<<<TEST_TYPE>>>" in line:
                if test_type == "Smoke":
                    lines[line_num] = line.replace("<<<TEST_TYPE>>>", "SmokeTest")
                elif test_type == "Performance":
                    lines[line_num] = line.replace("<<<TEST_TYPE>>>", "PerformanceTest")
                elif test_type == "Accuracy":
                    lines[line_num] = line.replace("<<<TEST_TYPE>>>", "AccuracyTest")
                elif test_type == "Stability":
                    lines[line_num] = line.replace("<<<TEST_TYPE>>>", "StabilityTest")
            line_num += 1
    except FileNotFoundError:
        print(f"Error: Log file '{curr_dir}/{template_file}' not found.")
    except Exception as e:
        print(f"Error reading file: {str(e)}")

    os.system(f"chmod 777 {target_file}")


if __name__ == "__main__":
    main()
