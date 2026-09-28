from camunda.external_task.external_task_worker import ExternalTaskWorker
import requests
import psycopg2, os

# Handler for "Store Vote"
def handle_store_vote(task):
    payload = task.variables
    try:
        # Use Docker service name + internal port
        response = requests.post("http://vote:80/vote", json=payload)
        print("Store Vote response:", response.text)
    except Exception as e:
        print("Error storing vote:", e)
        return task.failure(error_message=str(e), error_details="Vote API failed")
    return task.complete()

# Handler for "Process Vote"
def handle_process_vote(task):
    try:
        conn = psycopg2.connect(os.environ["DATABASE_URL"])
        cur = conn.cursor()
        option = task.variables.get("option")
        cur.execute("UPDATE votes SET count = count + 1 WHERE option = %s", (option,))
        conn.commit()
        cur.close()
        conn.close()
        print("Processed vote:", option)
    except Exception as e:
        print("Error processing vote:", e)
        return task.failure(error_message=str(e), error_details="DB update failed")
    return task.complete()

# Handler for "Store Result"
def handle_store_result(task):
    try:
        response = requests.post("http://result:80/result", json=task.variables)
        print("Store Result response:", response.text)
    except Exception as e:
        print("Error storing result:", e)
        return task.failure(error_message=str(e), error_details="Result API failed")
    return task.complete()

# Create worker and subscribe to topics
worker = ExternalTaskWorker(
    worker_id="unified-worker",
    base_url=os.environ.get("CAMUNDA_URL", "http://camunda:8080/engine-rest")
)

worker.subscribe("vote-processing", handle_store_vote)
worker.subscribe("process-vote", handle_process_vote)
worker.subscribe("store-result", handle_store_result)
