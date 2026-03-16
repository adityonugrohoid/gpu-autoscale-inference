FROM vllm/vllm-openai:latest
ENV HF_HOME=/root/.cache/huggingface
RUN python3 -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen2.5-1.5B-Instruct')"
