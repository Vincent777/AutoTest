#!/usr/bin/env bash

cleanup() {
    # Ignore further signals: resetting to default would let a second SIGPIPE
    # kill us when we write to the already-broken SSH stdout pipe.
    trap - SIGINT SIGTERM SIGHUP SIGPIPE
    exec >> "${curr_dir}/cleanup.log" 2>&1
    echo "$(date '+%F %T') Stopping CI test job CI_test_job_${CI_job_id}..."
    docker stop --timeout 60 "CI_test_job_${CI_job_id}" || true
    # rm -rf $curr_dir
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

curr_dir=$(pwd)

docker run --rm --name="CI_test_job_${CI_job_id}" --privileged -v /home/s_limingge/.npu_locks:/home/s_limingge/.npu_locks -v /CI_Workspace:/CI_Workspace -v /var/run/docker.sock:/var/run/docker.sock auto-test:latest $platform $test_type $engine $model_list $CI_job_id $test_param $version &
CHILD_PID=$!

echo -n "Running"
while kill -0 $CHILD_PID 2>/dev/null; do
    # echo -ne "\r\033[KRunning..."
    echo -n "."
    sleep 1
done

wait $CHILD_PID
EXIT_CODE=$?

# If the docker-run client died (e.g. EPIPE on the broken SSH pipe after a
# cancel/timeout) the container may still be running: treat it as an abort.
# On normal completion the container has already exited and been removed.
if [ "$(docker inspect -f '{{.State.Running}}' "CI_test_job_${CI_job_id}" 2>/dev/null)" = "true" ]; then
    cleanup
fi

# rm -rf $curr_dir

exit $EXIT_CODE
