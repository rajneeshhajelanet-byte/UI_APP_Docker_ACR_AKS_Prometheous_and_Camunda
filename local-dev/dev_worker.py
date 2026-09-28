"""Local-only stand-in for worker/Program.cs.

The real worker needs the .NET SDK, which isn't installable on this machine.
This script reproduces the same logic in Python purely so the local vote ->
redis -> worker -> postgres -> result loop can be exercised end to end:
poll the Redis "votes" list, and upsert each vote into Postgres by voter_id.
Not a replacement for worker/Program.cs -- once a real .NET SDK is available,
use that instead.
"""
import json
import time

import pg8000.dbapi
import redis

REDIS_HOST = "127.0.0.1"
REDIS_PORT = 6379
PG_HOST = "127.0.0.1"
PG_PORT = 5432


def connect_redis():
    while True:
        try:
            conn = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, socket_timeout=5)
            conn.ping()
            print("Connected to redis stub")
            return conn
        except redis.exceptions.RedisError as exc:
            print(f"Waiting for redis ({exc})")
            time.sleep(1)


def connect_pg():
    while True:
        try:
            conn = pg8000.dbapi.connect(
                host=PG_HOST, port=PG_PORT, user="postgres", password="postgres", database="postgres"
            )
            conn.autocommit = True
            print("Connected to postgres stub")
            return conn
        except Exception as exc:  # pg8000 raises plain OSError/InterfaceError variants
            print(f"Waiting for db ({exc})")
            time.sleep(1)


def upsert_vote(cursor, voter_id, vote):
    cursor.execute(
        """
        INSERT INTO votes (voter_id, vote, created_at)
        VALUES (%s, %s, NOW())
        ON CONFLICT (voter_id) DO UPDATE SET vote = EXCLUDED.vote, created_at = NOW()
        """,
        (voter_id, vote),
    )


def main():
    r = connect_redis()
    pg = connect_pg()
    cur = pg.cursor()

    print("dev-worker: polling redis 'votes' list...")
    while True:
        try:
            item = r.blpop("votes", timeout=1)
        except redis.exceptions.RedisError as exc:
            print(f"Redis error, reconnecting ({exc})")
            r = connect_redis()
            continue

        if item is None:
            continue

        _, raw = item
        try:
            payload = json.loads(raw)
            vote = payload["vote"]
            voter_id = payload["voter_id"]
        except (json.JSONDecodeError, KeyError) as exc:
            print(f"Skipping malformed vote payload {raw!r}: {exc}")
            continue

        try:
            upsert_vote(cur, voter_id, vote)
            print(f"Processed vote for '{vote}' by '{voter_id}'")
        except Exception as exc:
            print(f"DB error, reconnecting ({exc})")
            pg = connect_pg()
            cur = pg.cursor()


if __name__ == "__main__":
    main()
