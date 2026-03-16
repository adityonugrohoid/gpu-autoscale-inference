import json
import os
import time

import httpx
import redis

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
VLLM_URL = os.getenv("VLLM_URL", "http://vllm:8000")
MODEL_ID = os.getenv("MODEL_ID", "Qwen/Qwen2.5-1.5B-Instruct")

r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


def wait_for_vllm():
    print("Waiting for vLLM readiness...")
    while True:
        try:
            httpx.get(f"{VLLM_URL}/health", timeout=2)
            print("vLLM ready.")
            return
        except Exception:
            time.sleep(5)


def process_job(job: dict):
    try:
        resp = httpx.post(
            f"{VLLM_URL}/v1/completions",
            json={"model": MODEL_ID, "prompt": job["prompt"]},
            timeout=120,
        )
        resp.raise_for_status()
        text = resp.json()["choices"][0]["text"]
        r.setex(
            f"result:{job['id']}",
            300,
            json.dumps({"status": "done", "response": text}),
        )
    except Exception as e:
        r.setex(
            f"result:{job['id']}",
            300,
            json.dumps({"status": "error", "message": str(e)}),
        )


if __name__ == "__main__":
    wait_for_vllm()
    print(f"Worker started. Consuming from inference_queue, vLLM at {VLLM_URL}")
    while True:
        _, raw = r.brpop("inference_queue")
        job = json.loads(raw)
        print(f"Processing job {job['id']}")
        process_job(job)
        print(f"Completed job {job['id']}")
