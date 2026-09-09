multiplier=1
concurrency_list=(1)
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
for pair in ${length_pairs[@]}; do
    input_len=$(echo $pair | cut -d ':' -f 1)
    output_len=$(echo $pair | cut -d ':' -f 2)

    echo "========================================================"
    echo "Random Testing input=$input_len, output=$output_len"
    echo "========================================================"

    for concurrency in ${concurrency_list[@]}; do
        if [ $input_len -ge 30000 ] && [ $concurrency -gt 5 ]; then
            break
        fi
        
        prompts=$((concurrency * ${multiplier}))
        echo "Testing concurrency=$concurrency, prompts=$prompts"
        echo "python3 -m sglang.benchmark.serving --backend sglang --host 0.0.0.0 --port 8000 --model /software/models/Meta-Llama-3.1-70B-Instruct/ --tokenizer /software/models/Meta-Llama-3.1-70B-Instruct/ --dataset-name random --dataset-path /home/s_limingge/ShareGPT_V3_unfiltered_cleaned_split.json --random-input-len $input_len --random-output-len $output_len --num-prompts $prompts --request-rate inf --max-concurrency $concurrency"
        python3 -m sglang.benchmark.serving \
        --backend sglang \
        --host 0.0.0.0 \
        --port 8000 \
        --model /software/models/Meta-Llama-3.1-70B-Instruct/ \
        --tokenizer /software/models/Meta-Llama-3.1-70B-Instruct/ \
        --dataset-name random \
        --dataset-path /software/models/ShareGPT_V3_unfiltered_cleaned_split.json \
        --random-input-len $input_len \
        --random-output-len $output_len \
        --num-prompts $prompts \
        --request-rate inf \
        --max-concurrency $concurrency
    done
done