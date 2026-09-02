import argparse
import multiprocessing
import subprocess
import time
import sys
import os
import signal
import socket
import traceback


def start_process(command, env_vars=None):
    """启动子进程，并设置单独的环境变量"""
    env = os.environ.copy()  # 复制当前环境变量
    if env_vars:
        env.update(env_vars)  # 添加额外的环境变量
    return subprocess.Popen(command, env=env, start_new_session=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Pagoda launcher for ascend_resource_monitor")
    parser.add_argument(
        "--test_type",
        choices=["Service", "Performance"],
        default="Service",
        help="Test type: Service (Stability) or Performance. Default: Service",
    )
    args = parser.parse_args()

    file_path, file_name = os.path.split(__file__)
    api_server_script = os.path.join(f"{file_path}", "ascend_resource_monitor.sh")
    multiprocessing.set_start_method("spawn")
    master_process = None

    if args.test_type == "Performance":
        cmd = ["bash", api_server_script, "Performance", "SigInfer",
               "DeepSeek-R1-0528", "000000", "Random", "main-b1a01d5e"]
    else:
        # Service -> Stability
        cmd = ["bash", api_server_script, "Stability", "SigInfer",
               "DeepSeek-R1-0528", "000000", "main-b1a01d5e"]
    master_process = start_process(cmd)

    # Handle Ctrl+C, ensure all processes are terminated
    def terminate_processes(signum, frame):
        print("Shutting down all processes...")
        if master_process:
            print("Shutting down master process")
            # master_process.terminate()
            os.killpg(master_process.pid, signal.SIGTERM)
            time.sleep(30)
            if master_process.poll() is None:
                os.killpg(master_process.pid, signal.SIGKILL)

        print("inference engine terminated.")
        sys.exit(0)

    # Listen for Ctrl+C (SIGINT) signal
    signal.signal(signal.SIGINT, terminate_processes)

    # **Keep `launcher.py` running**
    if master_process:
        master_process.wait()
