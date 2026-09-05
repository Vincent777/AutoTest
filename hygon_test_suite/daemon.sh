#!/usr/bin/env bash
set -m

cleanup() {
    trap - SIGINT SIGTERM SIGHUP SIGPIPE
    echo "Stopping CI test job..."
    docker stop --timeout 60 CI_test_job_${platform}_${test_type}_${CI_job_id}
    docker stop --time 60 CI_test_job_${platform}_${test_type}_${CI_job_id}
    exit 130
}

trap cleanup SIGINT SIGTERM SIGHUP SIGPIPE

platform=$1
test_type=$2
engine=$3
model_list=$4
CI_job_id=$5
test_param=$6
version=$7

# 兼容旧签名（含 docker_args）
if [ "$#" -ge 8 ]; then
    CI_job_id=$6
    test_param=$7
    version=$8
fi

curr_dir=$(pwd)

docker run --rm --name="CI_test_job_${platform}_${test_type}_${CI_job_id}" \
  --ipc=host --net=host --privileged \
  -v /root/.npu_locks:/root/.npu_locks \
  -v /data/shared/limingge/CI_Workspace_for_InfiniLM:/CI_Workspace \
  -v /data-aisoft/artifacts:/artifacts \
  -v ~/.ssh:/root/.ssh \
  -v /var/run/docker.sock:/var/run/docker.sock \
  auto-test:latest \
  $platform $test_type $engine $model_list $CI_job_id $test_param $version &
CHILD_PID=$!

echo -n "Running"
while kill -0 $CHILD_PID 2>/dev/null; do
    echo -n "."
    sleep 1
done

wait $CHILD_PID
EXIT_CODE=$?

exit $EXIT_CODE
