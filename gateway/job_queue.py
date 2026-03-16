import json
import os
import uuid

import redis

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


def enqueue_request(prompt: str) -> str:
    job_id = str(uuid.uuid4())
    r.lpush("inference_queue", json.dumps({"id": job_id, "prompt": prompt}))
    return job_id


def get_result(job_id: str) -> dict | None:
    raw = r.get(f"result:{job_id}")
    if raw is None:
        return None
    return json.loads(raw)
