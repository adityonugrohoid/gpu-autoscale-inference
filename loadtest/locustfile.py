import time

from locust import HttpUser, between, task


class LLMUser(HttpUser):
    wait_time = between(1, 3)

    @task
    def generate_and_poll(self):
        resp = self.client.post("/generate", json={
            "prompt": "Write a detailed analysis of how Kubernetes autoscaling works "
            "with event-driven architectures, covering KEDA queue-based triggers, "
            "Cluster Autoscaler node provisioning, GPU scheduling with tolerations "
            "and resource requests, and the complete lifecycle from idle state "
            "through scale-up, inference serving, and scale-to-zero. Include "
            "specific examples of how Redis queue depth drives pod scaling "
            "decisions and how pending GPU pods trigger node-level autoscaling "
            "in cloud environments like GKE and AKS."
        })
        job_id = resp.json().get("job_id")
        if not job_id:
            return

        for _ in range(30):
            r = self.client.get(
                f"/result/{job_id}",
                name="/result/[job_id]",
            )
            if r.json().get("status") != "pending":
                break
            time.sleep(2)
