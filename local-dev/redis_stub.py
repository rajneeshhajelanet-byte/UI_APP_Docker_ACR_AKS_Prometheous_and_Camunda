"""In-memory Redis-protocol server, standing in for a real Redis server that
can't be installed on this machine. Speaks real RESP over a real TCP socket,
so the actual `redis` client used by vote/app.py works against it unmodified.
"""
from fakeredis import TcpFakeServer

if __name__ == "__main__":
    server = TcpFakeServer(("127.0.0.1", 6379), server_type="redis")
    print("Redis stub (fakeredis) listening on 127.0.0.1:6379")
    server.serve_forever()
