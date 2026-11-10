# Private LLM Stack — evaluating on-prem LLMs for IT self-service and agentic coding

The code, scripts and measured results from a two-stage pilot into running language models on hardware the IT team already owned: first a **RAG assistant over the IT knowledge base** on CPU and then GPU hosts, then a **local coding-model lab** to test whether an on-prem model could take work off a metered cloud coding assistant.

**Status:** pilot / sandbox. Nothing here is a production service, and **no cost savings are claimed** (see "What it showed"). Numbers are from single-operator test runs and are labelled with their limits.

> This repository has been scrubbed of identifying information (company, host names, addresses, accounts). Addresses use documentation ranges (192.0.2.x) and hosts are generic (`ai02`, `ai04`).

---

## Why this exists

IT was handed a pile of freed server blades (and later a GPU server) and a fair question: *is an on-prem LLM useful, and for what?* Cloud AI subscriptions were already in the estate, so on-prem only earns its keep on data sovereignty, sustained volume, or specific cost levers. The pilot set out to answer that with measurements instead of opinions, for two concrete jobs:

1. **Self-service answers from the KB** — "how do I fix X" answered from real articles, with data staying on-prem, inside a 20-second serverless time budget.
2. **A cheaper coding assistant for infrastructure work** — can a local model handle short and medium agentic jobs so the metered cloud assistant is only used where it must be?

## Why it was built this way

- **A deterministic RAG proxy instead of the chat UI's built-in RAG.** Both of Open WebUI's built-in mechanisms were unreliable with small quantized models: the tool-based path had models *narrate* a search as plain text (one fabricated a search result and an article ID), and the "legacy" static-injection path never fired even though the flag demonstrably reached the right code. `rag-proxy/` (a small FastAPI service) does retrieval itself: embed the question, search Qdrant directly, inject the chunks into the system prompt, forward to LiteLLM. The chat UI just sees one more OpenAI-compatible model. Verified end to end against a real article: the grounded answer used ~1,091 prompt tokens versus ~150–200 for the hallucinated built-in-RAG answers. Lesson kept: "the answer sounds plausible" is not proof of grounding; check it against the source article.
- **Answer behavior is encoded, not hoped for.** The proxy only answers from articles marked public (a visibility map filters everything else *before* the model sees it), cites the real article URL, asks one clarifying question only when candidate articles give conflicting steps, and offers to open a ticket instead of guessing when nothing matches.
- **LiteLLM as the single front door** so models and routes can change without touching clients, and so a future cloud route can sit beside the local one under one governance point.
- **Pick hardware by memory bandwidth, not CPU name.** CPU inference without AMX is memory-bandwidth-bound. Bandwidth ≈ populated channels × clock: a newer CPU running 6 of 8 channels at 2666 (~128 GB/s/socket) lost to an older, fully-populated 6-channel node at 2933 (~141 GB/s/socket), so the pilot node was chosen from live inventory, not the spec sheet.
- **Reproducible, comparable benchmarks.** One fixed question, the *full assembled prompt* as the prefill numerator (using just the question understated prefill ~35×), a warm-up run discarded, three timed runs averaged, GPU telemetry sampled during inference. Methodology is in `docs/benchmark-methodology.md`.
- **Agents run contained.** Autonomous coding agents were tested only inside a locked-down Docker container (non-root, capabilities dropped, read-only root filesystem), never directly on a host.

## What it showed

**Stage 1 — KB RAG assistant (same fixed question, ~1,600-word assembled prompt):**

| | CPU blade (dual Xeon Gold 6230) | 2× NVIDIA A400 | 2× NVIDIA L4 |
|---|---|---|---|
| Reading the question (prefill) | 145 words/s | 729 words/s | ~11,400 words/s |
| Writing the answer (decode) | 13.8 words/s | 16.9 words/s | 48.4 words/s |
| Time to first word | 11.1 s | 2.2 s | 0.12 s |
| Total response | ~18 s | ~8 s | 2.7 s |
| Fits a 20 s budget | no | no | **yes** |

Operational lesson on the L4 host: the passive-cooled GPUs idled at 78 °C under the server's default thermal profile (5 °C from throttling); setting the chassis to maximum cooling dropped idle to ~30 °C with a 54 °C peak under full load.

**Stage 2 — local coding-model lab (2× L4, sandbox):**

- Qwen3-Coder-Next (80B MoE, 3B active, Q4_K_M) served by llama.cpp as a systemd service behind LiteLLM. Decode ~46 tok/s at ~8k context falling to ~35 tok/s at ~81k; **cold prefill is the real cost** (~416–514 tok/s, so a cold 41k-token context is ~99 s) while a warm, prefix-cached repeat returns in 0.1–0.2 s. Usable for patient users if the prompt cache survives.
- A small auto-scored bake-off (5 jobs: a PowerShell function checklist, two Python tasks with executed tests, find-the-bug, a 3-turn tool chain; temperature 0): Qwen3-Coder-Next 4/5 in 36 s; Qwen3.6-27B 4/5 in 114 s with thinking off and **5/5 in 1,002 s** with thinking on (about 28× the wall time); Devstral Small 2 4/5; Gemma 4 31B 4/5 (382 s); two Hermes models 3/5 and 2/5. Speculative (MTP) decoding roughly doubled speed on the 27B model with 82–93% draft acceptance. Best speed-to-quality for interactive use: Qwen3-Coder-Next.
- Agent harness test, contained: OpenCode fixed a buggy file in 41 s, Qwen Code in 93 s.
- Concurrency matters: with one slot, three simultaneous requests serialized (18.6 s worst, 48 tok/s aggregate); with three slots all finished in ~10 s at 87–94 tok/s aggregate.
- Throughput ceiling with the llama.cpp server on this box, measured with the community [llama-throughput-lab](https://github.com/alexziskind1/llama-throughput-lab) (MIT, Alex Ziskind; a tool used for vetting, not part of this repo): roughly 2,000 tok/s aggregate for an 8B Q4 model at 4 instances × 48 slots. That is a decode-heavy, short-prompt figure, **not** a RAG figure.
- vLLM tensor-parallel across the two PCIe-only GPUs worked only with specific flags and gave no single-stream speed gain over llama.cpp.

**Honest limits:** the bake-off is one run per job over five jobs; the benchmark hosts are different generations of hardware; the lab host is a sandbox. Routing a cloud coding assistant to a non-vendor model through a gateway is unsupported by the vendor, and was not tested end to end. The cost-reduction settings that would be tried first were never applied, so **no savings have been demonstrated**. The finding is where a local model fits (short and medium jobs, read-only lookups, KB drafting) and where it fits worst (long, high-context agentic sessions: prefill and context memory dominate).

## Layout

```
rag-proxy/         FastAPI deterministic-RAG service (app.py, Dockerfile, article_visibility.json example)
stack/             compose.yaml + litellm-config.yaml: Qdrant + LiteLLM + Open WebUI + rag-proxy
ai04/              GPU sandbox rebuild: build-llama.sh, llama-server.service, LiteLLM-only compose + config
ai04/bakeoff/      auto-scored job set (jobs.py), model-swap runners, contained agent harness, vLLM timing
Deploy-LlmStack.ps1       idempotent host deploy (Docker, Ollama, models, secrets, compose); -WhatIf, -KeepSecrets, -GpuHost
Ingest-KbCorpus.ps1       load the KB corpus into Qdrant and wire rag-proxy to it
Install-NvidiaStack.ps1   driver/CUDA/container-toolkit setup on a GPU host
Invoke-LlmBenchmark.ps1   the fixed-question latency benchmark
New-LlmBladeSecrets.ps1 / New-Ai04SshKey.ps1   key and secret generation (nothing written to the repo)
docs/              benchmark methodology
```

## Stack

Python (FastAPI, Qdrant client), PowerShell 7, Docker Compose, Ollama, llama.cpp (CUDA), vLLM, LiteLLM, Open WebUI, Qdrant, NVIDIA CUDA, Ubuntu 24.04.

## Run it

```powershell
.\Deploy-LlmStack.ps1 -HostName ai02 -WhatIf     # dry run
.\Deploy-LlmStack.ps1 -HostName ai02             # deploy the stack
.\Ingest-KbCorpus.ps1 -Verbose                   # RAG corpus (see script header for one-time setup)
.\Invoke-LlmBenchmark.ps1 -GpuHost -Verbose      # fixed-question benchmark
```

After editing `rag-proxy/app.py`, rebuild the image with `docker compose up -d --build`; use `--force-recreate` (not `docker restart`) to pick up `.env` changes. `rag-proxy/article_visibility.json` here is an illustrative two-entry sample: generate the real map from your KB export (1 = public). The bake-off scripts use the test tools from the llama-throughput-lab clone on the host. Secrets are generated at deploy time and kept out of the repo; review script headers before running anything against a real host.

## License

MIT — see `LICENSE`.
