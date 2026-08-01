#!/usr/bin/env bash
set -m

# Remember parent at start. If SSH session dies without delivering a signal,
# this shell is reparented to init (PPID=1) and we must stop the container ourselves.
INITIAL_PPID=$PPID
CLEANED=0

cleanup() {
    if [ "$CLEANED" = 1 ]; then
        return
    fi
    CLEANED=1
    trap - SIGINT SIGTERM SIGHUP SIGPIPE
    echo "Stopping CI test job CI_test_job_${CI_job_id}..."
    docker stop --time 60 "CI_test_job_${CI_job_id}" 2>/dev/null \
        || docker stop --timeout 60 "CI_test_job_${CI_job_id}" 2>/dev/null \
        || true
    # if [ -n "${CHILD_PID:-}" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    #     kill -TERM "$CHILD_PID" 2>/dev/null || true
    # fi
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
    # GitLab Cancel kills the SSH client; remote may become orphaned without trap signals.
    if [ "$INITIAL_PPID" -ne 1 ] && [ "$PPID" -eq 1 ]; then
        echo ""
        echo "Parent SSH session lost (orphaned); triggering cleanup..."
        cleanup
    fi
    echo -n "."
    sleep 1
done

wait $CHILD_PID
EXIT_CODE=$?

# rm -rf $curr_dir

exit $EXIT_CODE
