# ai04 lab (HPE DL380 Gen10, 2x L4)

Reproducible pieces for the sandbox; see `memory/ai04-llm-host.md`.

| File | Purpose |
|---|---|
| `compose.yaml` | LiteLLM only -> `/opt/llm/compose.yaml` (WebUI/RAG/Qdrant removed 2026-11-04; volumes kept) |
| `litellm-config.yaml` | Routes `qwen3-coder-next` to host llama-server `:8090` -> `/opt/llm/` |
| `build-llama.sh` | Build llama.cpp (CUDA sm_89) into a fresh dated dir |
| `llama-server.service` | systemd unit for llama-server (installed 2026-11-04, enabled, points at llama.cpp-20261104) |

Re-add the old KB-search stack from `LLM/stack/` and `LLM/rag-proxy/` if ever wanted.
