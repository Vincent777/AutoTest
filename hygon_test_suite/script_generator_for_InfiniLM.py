import yaml
import re
import os
import sys


# 需要先部署服务、再由父脚本压测/验收的测试类型
SERVER_DEPLOY_TYPES = {"Service", "Performance", "Smoke", "Accuracy", "Stability"}


def clean_card_type(card_type):
    """清理卡型，去掉括号中的内容和额外描述"""
    if not card_type:
        return None

    card_type = str(card_type).strip()
    card_type = re.sub(r'\s*\([^)]*\)', '', card_type)
    card_type = re.sub(r'\s+[^\w/]+.*$', '', card_type)
    return card_type.strip()


def extract_card_types(card_type_str):
    """从卡型字符串中提取所有卡型（可能包含多个，用顿号分隔）"""
    if not card_type_str:
        return []

    card_type_str = str(card_type_str).strip()
    card_types = [ct.strip() for ct in card_type_str.split('、')]

    cleaned_cards = []
    for ct in card_types:
        cleaned = clean_card_type(ct)
        if cleaned:
            if '/' in cleaned:
                parts = [p.strip() for p in cleaned.split('/')]
                for part in parts:
                    cleaned_cards.append(part)
            else:
                cleaned_cards.append(cleaned)

    return cleaned_cards


def escape_for_heredoc(text):
    """Escape $ so heredoc does not expand container-internal variables on the host."""
    return text.replace('$', r'\$')


def build_server_src_code(models, test_param):
    """按模型生成启动 inference_server 的分支代码，并返回 model_list 字符串。"""
    src_code = ""
    model_list = ""
    start = True
    for model in models:
        name = (model or {}).get('model_name')
        GPU = (model or {}).get('card_type')
        args = (model or {}).get('default_params') or ''

        if not name or not GPU or not args:
            continue

        args = str(args).splitlines()[0].strip()

        match = re.search(r"--tp\s+(\d+)", args)
        npu_quantity = match.group(1) if match else "1"
        model_list += f"{name}:{npu_quantity}:{GPU} "

        result = re.sub(r"--port(=|\s+)\S+", "--port $PORT", args)
        result = re.sub(r"--node-rank(=|\s+)\S+", "--node-rank $NODE_RANK", result)

        card_types = extract_card_types(GPU)
        for card_type in card_types:
            if start:
                src_code += f"if [ \"${{MODEL}}_${{GPU_MODEL}}\" == \"{name}_{card_type}\" ]; then\n"
                start = False
            else:
                src_code += f"elif [ \"${{MODEL}}_${{GPU_MODEL}}\" == \"{name}_{card_type}\" ]; then\n"
            src_code += "    echo \"SIG_LOG_LEVEL='warn,console_logger=info' ./start.sh "
            src_code += result
            if test_param and test_param not in ("Random", "SharedGPT", "default", ""):
                src_code += " ${TEST_PARAM}"
            src_code += "\"\n"
            # ENTRYPOINT 会 exec "$@"，必须以 ./start.sh 开头，不能裸传 --device/--model
            src_code += "    EXEC_COMMAND+=\" ./start.sh "
            src_code += result
            if test_param and test_param not in ("Random", "SharedGPT", "default", ""):
                src_code += " ${TEST_PARAM}"
            src_code += " > $LOG_PATH/$LOG_NAME 2>&1 &\"\n"
    src_code += "fi\n"
    return src_code, model_list.rstrip()


def main():
    if len(sys.argv) != 5:
        print("Usage: python script_generator_for_InfiniLM.py <test_type> <docker_args> <test_param> <version>")
        sys.exit(1)

    test_type = sys.argv[1]
    docker_args = sys.argv[2]
    test_param = sys.argv[3]
    version = sys.argv[4]

    curr_dir = os.getcwd()

    yaml_candidates = [
        f'{curr_dir}/{version}/model_list.yml',
        f'{curr_dir}/{version}/model_list.yaml',
    ]
    file_path = None
    for candidate in yaml_candidates:
        if os.path.exists(candidate):
            file_path = candidate
            break
    if not file_path:
        print(f"Error: YAML config not found for version '{version}'. Tried: {', '.join(yaml_candidates)}")
        sys.exit(1)

    with open(file_path, 'r', encoding='utf-8') as f:
        cfg = yaml.safe_load(f) or {}

    models = cfg.get('models', [])
    if not isinstance(models, list):
        print("Error: YAML key 'models' must be a list.")
        sys.exit(1)

    target_file = f"InfiniLM_job_executor_for_{test_type}Test_{test_param}.sh"
    src_code = ""
    log_path = ""
    model_list = "None"

    type_token_map = {
        "Inference": "InferenceTest",
        "Bench": "BenchTest",
        "Service": "ServiceTest",
        "Performance": "PerformanceTest",
        "Smoke": "SmokeTest",
        "Accuracy": "AccuracyTest",
        "Stability": "StabilityTest",
    }
    if test_type not in type_token_map:
        print(f"Error: unsupported test_type '{test_type}'")
        sys.exit(1)

    if test_type in SERVER_DEPLOY_TYPES:
        src_code, model_list = build_server_src_code(models, test_param)
        m = re.search(r"-v\s+(/[^:\s]+):/artifacts", docker_args)
        log_path = m.group(1) if m else "/data-aisoft/artifacts"

    template_file = "job_executor_template_for_InfiniLM.sh"

    try:
        with open(f"{curr_dir}/{template_file}", 'r', encoding='utf-8') as file:
            lines = file.readlines()

        line_num = 0
        for line in lines:
            if "<<<generated source code>>>" in line:
                if test_type in SERVER_DEPLOY_TYPES:
                    lines[line_num] = src_code
                else:
                    lines[line_num] = line.replace("<<<generated source code>>>", "")
            elif "<<<TEST_TYPE>>>" in line:
                lines[line_num] = line.replace("<<<TEST_TYPE>>>", type_token_map[test_type])
            elif "<<<LOG_PATH>>>" in line:
                lines[line_num] = line.replace("<<<LOG_PATH>>>", log_path)
            elif "<<<DOCKER_ARGS>>>" in line:
                if test_type in SERVER_DEPLOY_TYPES:
                    lines[line_num] = line.replace(
                        "<<<DOCKER_ARGS>>>",
                        docker_args + " $DOCKER_IMAGE_URL python InfiniLM/python/infinilm/server/inference_server.py",
                    )
                else:
                    lines[line_num] = line.replace(
                        "<<<DOCKER_ARGS>>>",
                        escape_for_heredoc(docker_args) + " 2>&1 &",
                    )
            line_num += 1

        with open(f"{curr_dir}/{target_file}", 'w') as file:
            file.write(''.join(lines))
    except FileNotFoundError:
        print(f"Error: Log file '{curr_dir}/{template_file}' not found.")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file: {str(e)}")
        sys.exit(1)

    os.system(f"chmod 777 {target_file}")

    if test_type in SERVER_DEPLOY_TYPES:
        print(model_list)
    else:
        print("None")


if __name__ == "__main__":
    main()
