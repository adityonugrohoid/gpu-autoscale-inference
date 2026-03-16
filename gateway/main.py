from fastapi import FastAPI
from pydantic import BaseModel

from job_queue import enqueue_request, get_result

app = FastAPI()


class GenerateRequest(BaseModel):
    prompt: str


@app.post("/generate")
async def generate(request: GenerateRequest):
    job_id = enqueue_request(request.prompt)
    return {"status": "queued", "job_id": job_id}


@app.get("/result/{job_id}")
async def result(job_id: str):
    data = get_result(job_id)
    if data is None:
        return {"status": "pending"}
    return data


@app.get("/health")
async def health():
    return {"status": "ok"}
