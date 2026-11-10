"""Cold/warm prefill + decode timing against an OpenAI-compatible endpoint (vLLM has no /completion).
Prefill ~= wall time of a max_tokens=1 request; decode = (wall(N tokens) - wall(1 token)) / (N-1).
Usage: python3 vllm_timing.py --base http://172.17.0.1:8090 --model bake --sizes 8000 40000
Authored by Caleb A. Morrow
Contributor: Claude - 2026-11-04 - initial version
"""
import argparse, json, time, urllib.request, random

SNIP = ("function Get-ServerHealth {\n    [CmdletBinding()]\n    param([Parameter(Mandatory)][string]$ComputerName)\n"
        "    try { $r = Invoke-Command -ComputerName $ComputerName -ScriptBlock { Get-Service | Where-Object Status -eq 'Stopped' } }\n"
        "    catch { Write-Error \"Failed to query $ComputerName: $_\" }\n    $r | Select-Object Name, DisplayName, Status\n}\n")

def post(base, payload):
    req = urllib.request.Request(base + "/v1/chat/completions", json.dumps(payload).encode(), {"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=3600) as r:
        d = json.load(r)
    return time.time() - t, d

def run(base, model, n, tag):
    salt = random.randint(0, 10**9)  # defeat prefix cache for the cold run
    body = f"# run {salt}\n" + SNIP * max(1, n // 110)
    msgs = [{"role": "user", "content": body + "\nReply with the single word OK."}]
    base_p = {"model": model, "messages": msgs, "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}
    w1, d1 = post(base, {**base_p, "max_tokens": 1})
    pt = d1["usage"]["prompt_tokens"]
    w2, d2 = post(base, {**base_p, "max_tokens": 129})   # warm (prefix cached) + 128 decode
    ct = d2["usage"]["completion_tokens"]
    dec = (w2 - 0.0) / max(ct, 1)
    print(f"[{tag}] prompt={pt} tok | {tag}-prefill+1tok={w1:.1f}s ({pt/w1:.0f} tok/s) | warm run {ct} tok in {w2:.1f}s (~{ct/w2:.1f} tok/s incl. cache hit)")

ap = argparse.ArgumentParser(); ap.add_argument("--base", default="http://172.17.0.1:8090"); ap.add_argument("--model", default="bake")
ap.add_argument("--sizes", type=int, nargs="+", default=[8000, 40000]); a = ap.parse_args()
for n in a.sizes:
    run(a.base, a.model, n, f"{n//1000}k")
