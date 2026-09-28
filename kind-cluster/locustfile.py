from locust import HttpUser, task, between

class VotingUser(HttpUser):
    wait_time = between(1, 3)

    @task(2)
    def vote(self):
        self.client.get("/")

    @task(1)
    def result(self):
        self.client.get("/result")
