#!/usr/bin/env bash
# vLLM variant of the bake-off runner (OpenAI API only). Stops llama-server, serves with vLLM
# on 172.17.0.1:8090, runs toolcall + timing + PS task, then restores llama-server.
# Usage: run-bakeoff-vllm.sh <label> <model-dir-or-id> [extra vllm serve args...]
# Authored by Caleb A. Morrow
# Contributor: Claude - 2026-11-04 - initial version
set -uo pipefail
LABEL="$1"; MODEL="$2"; shift 2
OUT=~/llama-lab/bakeoff; mkdir -p "$OUT"; LOG="$OUT/$LABEL.log"; BASE=http://172.17.0.1:8090
TOOLS=/home/admin/llama-lab/tools
sudo systemctl stop llama-server
echo "=== $LABEL $(date -Is) model=$MODEL extra=$*" | tee "$LOG"
NCCL_P2P_DISABLE=1 VLLM_USE_FLASHINFER_SAMPLER=0 PATH=/srv/models/venv/vllm/bin:$PATH HF_HOME=/srv/models/hf nohup /srv/models/venv/vllm/bin/vllm serve "$MODEL" --host 172.17.0.1 --port 8090 --served-model-name bake "$@" > "$OUT/$LABEL.server.log" 2>&1 &
SPID=$!
for i in $(seq 1 180); do curl -sf $BASE/health >/dev/null && break; kill -0 $SPID 2>/dev/null || break; sleep 5; done
if ! curl -sf $BASE/health >/dev/null; then echo "SERVER FAILED TO START" | tee -a "$LOG"; tail -20 "$OUT/$LABEL.server.log" | tee -a "$LOG"; kill $SPID 2>/dev/null; pkill -f "venv/vllm/bin" 2>/dev/null; sleep 8; sudo systemctl start llama-server; exit 1; fi
echo "--- toolcall" | tee -a "$LOG"; python3 $TOOLS/toolcall_test.py --base $BASE --model bake 2>&1 | tee -a "$LOG"
echo "--- timing" | tee -a "$LOG"; python3 ~/llama-lab/vllm_timing.py --base $BASE --model bake 2>&1 | tee -a "$LOG"
echo "--- powershell task" | tee -a "$LOG"
curl -s $BASE/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"bake","temperature":0,"max_tokens":8000,"messages":[{"role":"user","content":"Write a PowerShell function Get-StaleAdComputer that finds AD computer accounts not logged on in N days. Requirements: [CmdletBinding()], param(), approved verbs, comment-based help, Try/Catch/Finally, -WhatIf support via SupportsShouldProcess for a Disable switch, timestamped logging. Output only the code."}]}' \
 | python3 -c 'import sys,json,time; r=json.load(sys.stdin); m=r["choices"][0]["message"]; print(m.get("content") or "[EMPTY]"); print("USAGE", r.get("usage"))' > "$OUT/$LABEL.ps1.txt"
tail -1 "$OUT/$LABEL.ps1.txt" | tee -a "$LOG"
grep -E "Avg generation throughput|Avg prompt throughput" "$OUT/$LABEL.server.log" | tail -3 | tee -a "$LOG"
kill $SPID; pkill -f "venv/vllm/bin" 2>/dev/null; wait $SPID 2>/dev/null; sleep 10
sudo systemctl start llama-server; echo "=== done $LABEL" | tee -a "$LOG"
