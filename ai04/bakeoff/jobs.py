"""Job-set scorer for the ai04 bake-off. Stdlib only; talks to any OpenAI-compatible endpoint.
Each job is auto-scored (regex checklist, executed unit tests, or tool-call checks).
Usage: python3 jobs.py --base http://172.17.0.1:8090 --model bake --label NAME [--think on|off|default]
Authored by Caleb A. Morrow
Contributor: Claude - 2026-11-04 - initial version
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request


def chat(base, model, messages, think, max_tokens=8000, tools=None):
    p = {"model": model, "messages": messages, "temperature": 0, "max_tokens": max_tokens}
    if think in ("on", "off"):
        p["chat_template_kwargs"] = {"enable_thinking": think == "on"}
    if tools:
        p["tools"] = tools
    req = urllib.request.Request(base + "/v1/chat/completions", json.dumps(p).encode(),
                                 {"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=1800) as r:
        d = json.load(r)
    m = d["choices"][0]["message"]
    return m, time.time() - t, d.get("usage", {})


def code_of(text):
    blocks = re.findall(r"```[a-zA-Z]*\n(.*?)```", text or "", re.S)
    return max(blocks, key=len) if blocks else (text or "")


# ---- job 1: PowerShell function checklist
PS_PROMPT = ("Write a PowerShell function Get-StaleAdComputer that finds AD computer accounts not logged on in N days. "
             "Requirements: [CmdletBinding()], param(), approved verbs, comment-based help, Try/Catch/Finally, -WhatIf "
             "support via SupportsShouldProcess for a Disable switch, timestamped logging. Output only the code.")


def score_ps(text):
    c = code_of(text)
    checks = {
        "function decl": re.search(r"(?im)^\s*function\s+Get-StaleAdComputer\b", c),
        "CmdletBinding": "CmdletBinding" in c,
        "SupportsShouldProcess": "SupportsShouldProcess" in c,
        "ShouldProcess call": ".ShouldProcess(" in c,
        "help": ".SYNOPSIS" in c,
        "try": re.search(r"try\s*\{", c),
        "catch": re.search(r"catch\s*\{", c),
        "finally": re.search(r"finally\s*\{", c),
        "timestamp": "Get-Date" in c,
        "AD query": re.search(r"Get-ADComputer|Search-ADAccount", c),
    }
    miss = [k for k, v in checks.items() if not v]
    return not miss, ("missing: " + ", ".join(miss)) if miss else "all 10 checks"


# ---- jobs 2-3: Python with executed tests
PY1_PROMPT = ("Write a Python function `parse_ping(output: str) -> dict` that parses Windows `ping` output and returns "
              "{'sent':int,'received':int,'lost':int,'min_ms':int,'max_ms':int,'avg_ms':int}. Handle 100% loss "
              "(no timing line: ms values None). Output only the code in one block.")
PY1_TEST = '''
from solution import parse_ping
ok = """Pinging 10.0.0.1 with 32 bytes of data:
Reply from 10.0.0.1: bytes=32 time=2ms TTL=64
Reply from 10.0.0.1: bytes=32 time=4ms TTL=64
Request timed out.
Reply from 10.0.0.1: bytes=32 time<1ms TTL=64

Ping statistics for 10.0.0.1:
    Packets: Sent = 4, Received = 3, Lost = 1 (25% loss),
Approximate round trip times in milli-seconds:
    Minimum = 0ms, Maximum = 4ms, Average = 2ms"""
r = parse_ping(ok)
assert r == {"sent": 4, "received": 3, "lost": 1, "min_ms": 0, "max_ms": 4, "avg_ms": 2}, r
dead = """Pinging 10.0.0.9 with 32 bytes of data:
Request timed out.
Request timed out.

Ping statistics for 10.0.0.9:
    Packets: Sent = 2, Received = 0, Lost = 2 (100% loss),"""
r = parse_ping(dead)
assert r["sent"] == 2 and r["received"] == 0 and r["lost"] == 2 and r["min_ms"] is None and r["avg_ms"] is None, r
print("OK")
'''
PY2_PROMPT = ("Write a Python function `merge_ranges(ranges: list[tuple[int,int]]) -> list[tuple[int,int]]` that merges "
              "overlapping or touching inclusive integer ranges (e.g. [(1,3),(2,5),(7,8),(8,9)] -> [(1,5),(7,9)]), returns "
              "sorted output, handles empty input and unsorted input without mutating the argument. "
              "Output only the code in one block.")
PY2_TEST = '''
from solution import merge_ranges
a = [(8, 9), (1, 3), (2, 5), (7, 8)]
b = list(a)
assert merge_ranges(a) == [(1, 5), (7, 9)]
assert a == b
assert merge_ranges([]) == []
assert merge_ranges([(1, 1), (2, 2)]) == [(1, 2)]
assert merge_ranges([(5, 10), (6, 7)]) == [(5, 10)]
print("OK")
'''


def run_py(text, test):
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "solution.py"), "w") as f:
            f.write(code_of(text))
        with open(os.path.join(d, "t.py"), "w") as f:
            f.write(test)
        try:
            r = subprocess.run([sys.executable, "t.py"], cwd=d, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            return False, "timeout"
        out = (r.stdout + r.stderr).strip().splitlines()
        return (r.returncode == 0 and "OK" in r.stdout), (out[-1] if out else "no output")[:150]


# ---- job 4: find the bug
BUG_PROMPT = ("This PowerShell snippet is supposed to return disks with under 10% free space. It returns wrong results. "
              "State the bug in one or two sentences, then give the fixed line.\n\n```powershell\n"
              "Get-CimInstance Win32_LogicalDisk -Filter \"DriveType=3\" |\n"
              "  Where-Object { ($_.FreeSpace / $_.Size) -lt 10 } | Select-Object DeviceID, FreeSpace, Size\n```")


def score_bug(text):
    t = (text or "").lower()
    ok = ("0.1" in t or "* 100" in t or "*100" in t or "percent" in t or "fraction" in t or "ratio" in t) and "-lt" in t
    return bool(ok), "identified ratio-vs-percent" if ok else "did not identify ratio vs percent"


# ---- job 5: three-turn tool chain
TOOLS = [
    {"type": "function", "function": {"name": "device42_search_devices",
     "description": "Search Device42 for devices by hostname substring.",
     "parameters": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}},
    {"type": "function", "function": {"name": "prtg_get_sensor_status",
     "description": "Get PRTG status for a device by exact hostname.",
     "parameters": {"type": "object", "properties": {"device": {"type": "string"}}, "required": ["device"]}}},
]


def tool_chain(base, model, think):
    msgs = [{"role": "system", "content": "You are an infrastructure assistant. Use tools; never describe calls in prose."},
            {"role": "user", "content": "Find the Device42 device whose name contains 'itsm' and tell me its PRTG status."}]
    m, t1, u1 = chat(base, model, msgs, think, 2000, TOOLS)
    n1 = u1.get("completion_tokens", 0)
    c = m.get("tool_calls") or []
    if not c or c[0]["function"]["name"] != "device42_search_devices":
        return False, "step1 wrong/no call", t1, n1
    msgs.append(m)
    msgs.append({"role": "tool", "tool_call_id": c[0].get("id", "c0"),
                 "content": json.dumps([{"name": "itsm01", "ip": "10.1.2.3"}])})
    m2, t2, u2 = chat(base, model, msgs, think, 2000, TOOLS)
    n2 = u2.get("completion_tokens", 0)
    c2 = m2.get("tool_calls") or []
    if (not c2 or c2[0]["function"]["name"] != "prtg_get_sensor_status"
            or "itsm01" not in json.dumps(c2[0]["function"]["arguments"])):
        return False, "step2 wrong/no call", t1 + t2, n1 + n2
    msgs.append(m2)
    msgs.append({"role": "tool", "tool_call_id": c2[0].get("id", "c1"),
                 "content": json.dumps({"status": "Up", "sensors_down": 0})})
    m3, t3, u3 = chat(base, model, msgs, think, 2000, TOOLS)
    fin = (m3.get("content") or "").lower()
    ok = ("up" in fin or "healthy" in fin) and not m3.get("tool_calls")
    return ok, "3-step chain ok" if ok else "bad final answer", t1 + t2 + t3, n1 + n2 + u3.get("completion_tokens", 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://172.17.0.1:8090")
    ap.add_argument("--model", default="bake")
    ap.add_argument("--label", default="run")
    ap.add_argument("--think", default="default", choices=["on", "off", "default"])
    a = ap.parse_args()
    rows = []

    def job(name, prompt, scorer):
        m, t, u = chat(a.base, a.model, [{"role": "user", "content": prompt}], a.think)
        text = m.get("content") or ""
        ok, why = scorer(text) if text else (False, "EMPTY content (ran out of tokens while thinking)")
        n = u.get("completion_tokens", 0)
        rows.append((name, ok, why, t, n))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: {why} | {t:.0f}s, {n} tok", flush=True)

    job("powershell function", PS_PROMPT, score_ps)
    job("python parse_ping (tests)", PY1_PROMPT, lambda t: run_py(t, PY1_TEST))
    job("python merge_ranges (tests)", PY2_PROMPT, lambda t: run_py(t, PY2_TEST))
    job("find the bug", BUG_PROMPT, score_bug)
    ok, why, t, n = tool_chain(a.base, a.model, a.think)
    rows.append(("tool chain (3 turns)", ok, why, t, n))
    print(f"[{'PASS' if ok else 'FAIL'}] tool chain (3 turns): {why} | {t:.0f}s, {n} tok", flush=True)
    p = sum(1 for r in rows if r[1])
    print(f"SUMMARY {a.label} think={a.think}: {p}/{len(rows)} passed, "
          f"{sum(r[3] for r in rows):.0f}s total, {sum(r[4] for r in rows)} completion tokens")


main()
