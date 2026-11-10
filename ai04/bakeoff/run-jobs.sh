#!/usr/bin/env bash
# Run the job set against a llama-server config:
#   run-jobs.sh <label> <think on|off|default> <gguf> [llama-server args...]
# Stops the systemd llama-server, serves the model on 172.17.0.1:8090, runs jobs.py, restores the service.
# Authored by Caleb A. Morrow
# Contributor: Claude - 2026-11-04 - initial version
set -uo pipefail
LABEL="$1"; THINK="$2"; GGUF="$3"; shift 3
BIN=${LLAMA_BIN:-/home/admin/llama-lab/llama.cpp-20261104/build/bin/llama-server}
OUT=~/llama-lab/bakeoff; LOG="$OUT/jobs-$LABEL.log"; BASE=http://172.17.0.1:8090
mkdir -p "$OUT"
sudo systemctl stop llama-server
echo "=== $LABEL think=$THINK $(date -Is) $GGUF $*" | tee "$LOG"
nohup "$BIN" -m "$GGUF" --host 172.17.0.1 --port 8090 --jinja --alias bake "$@" > "$OUT/jobs-$LABEL.server.log" 2>&1 &
SPID=$!
for i in $(seq 1 120); do curl -sf $BASE/health >/dev/null && break; kill -0 $SPID 2>/dev/null || break; sleep 5; done
if curl -sf $BASE/health >/dev/null; then
  python3 ~/llama-lab/jobs.py --base $BASE --model bake --label "$LABEL" --think "$THINK" 2>&1 | tee -a "$LOG"
else
  echo "SERVER FAILED TO START" | tee -a "$LOG"; tail -5 "$OUT/jobs-$LABEL.server.log" | tee -a "$LOG"
fi
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; sleep 8
sudo systemctl start llama-server
echo "=== done $LABEL" | tee -a "$LOG"
