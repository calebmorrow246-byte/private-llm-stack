#!/usr/bin/env bash
# Contained agent-harness test: give a coding agent a small repo with a failing test and score whether it fixes it.
#   harness-test.sh <opencode|qwen> <model-alias-served-on-8090> [label]
# The model must already be served on http://172.17.0.1:8090/v1 (the systemd llama-server does this).
#
# CONTAINMENT: the agent runs inside a Docker container as an unprivileged user (uid 1000), with all capabilities
# dropped, no-new-privileges, a read-only root filesystem, CPU/memory/pid limits, and ONLY the throwaway work
# folder mounted writable (Node + the agents are mounted read-only). It has no sudo and no access to the host
# filesystem, docker socket or credentials. Scoring also runs in a locked-down container with NO network.
# Pass = `python -m unittest` exits 0 after the agent runs.
#
# Authored by Caleb A. Morrow
# Contributor: Claude - 2026-11-04 - containerised version after the unsandboxed one was blocked
set -uo pipefail
H="$1"; MODEL="$2"; LABEL="${3:-$H-$MODEL}"
IMAGE=python:3.12-bookworm
OUT=~/llama-lab/bakeoff; mkdir -p "$OUT"
W=$(mktemp -d /tmp/harness.XXXXXX); chmod 777 "$W"; mkdir -p "$W/home"
cd "$W"
cat > inventory.py <<'PY'
def free_percent(free_bytes, total_bytes):
    """Return free space as a percentage (0-100), rounded to 1 decimal."""
    return round(free_bytes / total_bytes, 1)


def low_disks(disks, threshold=10):
    """Return the names of disks whose free percent is below threshold."""
    return [d["name"] for d in disks if free_percent(d["free"], d["total"]) < threshold]
PY
cat > test_inventory.py <<'PY'
import unittest
from inventory import free_percent, low_disks


class T(unittest.TestCase):
    def test_percent(self):
        self.assertEqual(free_percent(25, 200), 12.5)

    def test_low(self):
        disks = [{"name": "C", "free": 5, "total": 100}, {"name": "D", "free": 50, "total": 100}]
        self.assertEqual(low_disks(disks), ["C"])

    def test_zero_total(self):
        self.assertEqual(free_percent(0, 0), 0.0)


if __name__ == "__main__":
    unittest.main()
PY
cp test_inventory.py "$W/.test_inventory.orig"
if [ "$H" = "opencode" ]; then
  cat > opencode.json <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {"local": {"npm": "@ai-sdk/openai-compatible", "name": "local",
    "options": {"baseURL": "http://172.17.0.1:8090/v1", "apiKey": "none"},
    "models": {"$MODEL": {"name": "$MODEL", "tool_call": true, "limit": {"context": 65536, "output": 8192}}}}},
  "model": "local/$MODEL",
  "permission": {"edit": "allow", "bash": "allow"}
}
JSON
fi
chmod -R a+rwX "$W"

SANDBOX=(docker run --rm --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only
  --tmpfs /tmp:rw,size=256m --memory 4g --cpus 4 --pids-limit 512
  -v "$W":/work:rw -v /srv/models/node:/opt/node:ro -w /work
  -e HOME=/work/home -e PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin)

PROMPT="The unit tests in this repo fail. Run them, find the bugs in inventory.py, fix inventory.py (do not edit the tests), and re-run until they pass. Reply DONE when finished."
START=$(date +%s)
if [ "$H" = "opencode" ]; then
  timeout 900 "${SANDBOX[@]}" "$IMAGE" opencode run "$PROMPT" > "$OUT/harness-$LABEL.out" 2>&1
else
  timeout 900 "${SANDBOX[@]}" -e OPENAI_API_KEY=none -e OPENAI_BASE_URL=http://172.17.0.1:8090/v1 -e OPENAI_MODEL="$MODEL" \
    "$IMAGE" qwen --yolo -p "$PROMPT" > "$OUT/harness-$LABEL.out" 2>&1
fi
RC=$?
END=$(date +%s)
# score with pristine tests, no network, nothing writable except the work dir
cp "$W/.test_inventory.orig" "$W/test_inventory.py"
if docker run --rm --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only \
     --tmpfs /tmp:rw,size=64m -v "$W":/work:ro -w /work -e PYTHONDONTWRITEBYTECODE=1 "$IMAGE" python -m unittest >/dev/null 2>&1; then
  R=PASS; else R=FAIL; fi
echo "[$R] harness=$H model=$MODEL rc=$RC wall=$((END-START))s dir=$W" | tee -a "$OUT/harness-results.log"
tail -3 "$OUT/harness-$LABEL.out" | cut -c1-200
