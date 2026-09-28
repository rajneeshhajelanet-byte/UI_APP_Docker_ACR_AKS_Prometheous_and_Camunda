import os
import socket
import uuid
import logging
import json

from flask import Flask, render_template, request, make_response, jsonify
import redis

option_a = os.getenv('OPTION_A', "a")
option_b = os.getenv('OPTION_B', "b")
hostname = socket.gethostname()

app = Flask(__name__)

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
# NOT "REDIS_PORT": Kubernetes auto-injects that name for any pod sharing a
# namespace with a Service called "redis" (Docker-links-style env vars), as
# "tcp://<ip>:6379" -- colliding with our own int-typed override and crashing
# on startup with `ValueError: invalid literal for int()`.
REDIS_PORT = int(os.getenv('VOTE_REDIS_PORT', 6379))


def get_redis():
    if not hasattr(get_redis, 'conn'):
        get_redis.conn = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, socket_timeout=5)
    return get_redis.conn


def push_vote(vote, voter_id, source):
    data = {'vote': vote, 'voter_id': voter_id}
    get_redis().rpush('votes', json.dumps(data))
    app.logger.info('Received vote for %s [source=%s]', vote, source)


@app.route("/", methods=['GET', 'POST'])
def index():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = str(uuid.uuid4())

    vote = None

    if request.method == 'POST':
        vote = request.form['vote']
        push_vote(vote, voter_id, source='direct-ui')

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
    ))
    resp.set_cookie('voter_id', voter_id)
    return resp


@app.route("/vote", methods=['POST'])
def vote_api():
    """JSON endpoint used by the Camunda external task worker (see Camundaflow.py)."""
    payload = request.get_json(silent=True) or {}
    vote = payload.get('vote')
    if vote not in (option_a, option_b):
        return jsonify({'error': "vote must be '%s' or '%s'" % (option_a, option_b)}), 400

    voter_id = payload.get('voter_id') or str(uuid.uuid4())
    try:
        push_vote(vote, voter_id, source='camunda-orchestrated')
    except redis.exceptions.RedisError as exc:
        app.logger.error('Error storing vote: %s', exc)
        return jsonify({'error': str(exc)}), 503

    return jsonify({'status': 'ok', 'vote': vote, 'voter_id': voter_id})


@app.route("/healthz")
def healthz():
    try:
        get_redis().ping()
    except redis.exceptions.RedisError as exc:
        return jsonify({'status': 'error', 'redis': str(exc)}), 503
    return jsonify({'status': 'ok'})


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=int(os.getenv('PORT', 5000)), debug=True, use_reloader=False, threaded=True)
