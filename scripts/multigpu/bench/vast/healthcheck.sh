#!/usr/bin/env bash
# healthcheck.sh — docker's probe. While the entrypoint is still pulling the
# 103.7 GiB there is nothing to answer on $PORT, and calling that "unhealthy"
# would get the container killed on a cloud box. So: success until the
# entrypoint touches /tmp/.serving (right before it execs llama-server), then a
# real /health poll. /tmp/.serving is removed by the entrypoint on every start.
[ -f /tmp/.serving ] || exit 0
curl -fsS -m 8 "http://127.0.0.1:${PORT:-8009}/health" >/dev/null 2>&1 || exit 1
exit 0
