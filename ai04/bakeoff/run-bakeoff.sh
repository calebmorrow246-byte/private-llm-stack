#!/usr/bin/env bash
# Bake-off runner for ai04: swap the model served by llama-server, then run the same tests.
# Usage: run-bakeoff.sh <label> <gguf-path> [extra llama-server args...]
# Runs on ai04. Results append to ~/llama-lab/bakeoff/<label>.log
# Tests: toolcall_test.py (4 checks), prefill_test.py (cold/warm at 8k and 40k), one PowerShell
# generation prompt (saved for manual/lint scoring).
# Authored by Caleb A. Morrow
# Contributor: Claude - 2026-11-04 - initial bake-off runner
set -euo pipefail
LABEL="$1"; GGUF="$2"; shift 2
EXTRA=("$@")
BIN=/home/admin/llama-lab/llama.cpp-20261104/build/bin/llama-server
TOOLS=/home/admin/llama-lab/tools
OUT=~/llama-lab/bakeoff; mkdir -p "$OUT"; LOG="$OUT/$LABEL.log"
BASE=http://172.17.0.1:8090

sudo systemctl stop llama-server
echo "=== $LABEL $(date -Is) model=$GGUF extra=${EXTRA[*]:-}" | tee "$LOG"
nohup "$BIN" -m "$GGUF" --host 172.17.0.1 --port 8090 --jinja --alias bake "${EXTRA[@]}" > "$OUT/$LABEL.server.log" 2>&1 &
SPID=$!
for i in $(seq 1 120); do curl -sf $BASE/health >/dev/null && break; sleep 5; done
curl -sf $BASE/health >/dev/null || { echo "SERVER FAILED TO START" | tee -a "$LOG"; kill $SPID || true; exit 1; }

echo "--- toolcall" | tee -a "$LOG"
python3 "$TOOLS/toolcall_test.py" --base $BASE --model bake 2>&1 | tee -a "$LOG" || true
echo "--- prefill" | tee -a "$LOG"
python3 "$TOOLS/prefill_test.py" --sizes 8000 40000 --base $BASE --predict 128 2>&1 | tee -a "$LOG" || true
echo "--- powershell task" | tee -a "$LOG"
curl -s $BASE/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"bake","temperature":0,"max_tokens":8000,"messages":[{"role":"user","content":"Write a PowerShell function Get-StaleAdComputer that finds AD computer accounts not logged on in N days. Requirements: [CmdletBinding()], param(), approved verbs, comment-based help, Try/Catch/Finally, -WhatIf support via SupportsShouldProcess for a Disable switch, timestamped logging. Output only the code."}]}' \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); m=r["choices"][0]["message"]; print(m.get("content") or "[EMPTY CONTENT; reasoning chars=%d]" % len(m.get("reasoning_content") or "")); print("TIMINGS", r.get("timings"))' > "$OUT/$LABEL.ps1.txt"
tail -2 "$OUT/$LABEL.ps1.txt" | tee -a "$LOG"
kill $SPID; wait $SPID 2>/dev/null || true
sudo systemctl start llama-server
echo "=== done $LABEL" | tee -a "$LOG"
