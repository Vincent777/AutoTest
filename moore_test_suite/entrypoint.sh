#!/usr/bin/env bash
set -m

cleanup() {
    trap - SIGINT SIGTERM SIGHUP SIGPIPE
    kill -SIGTERM -$CHILD_PID
    sleep 60
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

# 兼容旧 InfiniLM CI 签名：platform test_type engine model docker_args CI_job_id test_param version
if [ "$#" -ge 8 ]; then
    # docker_args 被传入时忽略，仅保留 SigInfer 参数位
    docker_args="$5"
    CI_job_id=$6
    test_param=$7
    version=$8
fi

mkdir -p ~/.ssh/
cat > ~/.ssh/config <<EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

cd /CI_Workspace

if [ ! -d ci_autotest ]; then
    git clone http://git.xcoresigma.com/xcore-sigma/autotest.git ci_autotest
    cd ci_autotest
else
    cd ci_autotest
    git fetch --all
    git reset --hard origin/main
    git pull origin main
fi

if [ $platform == "Ascend" ]; then
    cd ascend_test_suite
    mkdir -p $version
    cp latest/${engine}_model_list.xlsx $version
    ./ascend_resource_monitor.sh $test_type $engine $model_list $CI_job_id $test_param $version &
    CHILD_PID=$!
elif [ $platform == "Nvidia" ]; then
    cd nvidia_test_suite
    mkdir -p $version
    cp latest/${engine}_model_list.xlsx $version
    ./nvidia_resource_monitor.sh $test_type $engine $model_list $CI_job_id $test_param $version &
    CHILD_PID=$!
elif [ $platform == "Hygon" ]; then
    cd hygon_test_suite
    mkdir -p $version
    cp latest/${engine}_model_list.xlsx $version 2>/dev/null || cp latest/SigInfer_model_list.xlsx $version/
    ./hygon_resource_monitor.sh $test_type $engine $model_list $CI_job_id $test_param $version &
    CHILD_PID=$!
elif [ $platform == "Iluvatar" ]; then
    cd iluvatar_test_suite
    mkdir -p $version
    cp latest/${engine}_model_list.xlsx $version 2>/dev/null || cp latest/SigInfer_model_list.xlsx $version/
    ./iluvatar_resource_monitor.sh $test_type $engine $model_list $CI_job_id $test_param $version &
    CHILD_PID=$!
elif [ $platform == "Moore" ]; then
    cd moore_test_suite
    mkdir -p $version
    cp latest/${engine}_model_list.xlsx $version 2>/dev/null || cp latest/SigInfer_model_list.xlsx $version/
    ./moore_resource_monitor.sh $test_type $engine $model_list $CI_job_id $test_param $version &
    CHILD_PID=$!
fi

echo -n "Running"
while kill -0 $CHILD_PID 2>/dev/null; do
    echo -n "."
    sleep 1
done

wait $CHILD_PID
EXIT_CODE=$?

exit $EXIT_CODE
