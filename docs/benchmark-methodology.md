# Benchmark methodology

How the host comparison was run so future runs stay apples-to-apples. Applies to the KB RAG assistant measured end to end: user question → rag-proxy (embed → Qdrant → inject KB context) → LiteLLM → model.

## Fixed inputs
- One fixed benchmark question (~45 words: a VPN connection failure, with troubleshooting already tried). Never change it between hosts.
- Assembled prompt ≈ 1,600 words (~2,100 tokens): ~313 words of system instructions, top-5 KB chunks × ~248 words, ~45 words of question.

## Metrics
| Metric | How measured | Formula |
|---|---|---|
| Reading the question (prefill, words/s) | full assembled prompt ÷ time to first word | `(system + KB chunks + question words) / TTFW` |
| Writing the answer (decode, words/s) | actual output words ÷ decode time | `output_words / (total − TTFW)` |
| Time to first word (TTFW) | streaming: request sent → first token | measured in `Invoke-LlmBenchmark.ps1` |
| Total response time | request sent → `[DONE]` | same script |
| GPU peak temp / power | `nvidia-smi dmon -s pu -d 2` during inference | peak of the log |

## Protocol
1. Make sure the model is not already in VRAM (or discard the warm-up pass).
2. One warm-up (not counted) + three timed passes; average the three.
3. Discard a pass if its output word count differs by more than 30% (different code path).
4. Wait at least 10 s between passes (the runtime keeps the model loaded for ~5 minutes).
5. Check GPU offload before and after (`ollama ps`).

## Pitfalls
- Use the **full prompt** words as the prefill numerator. Using only the question understates prefill ~35×.
- Count real whitespace-split output words, not `tokens × 0.75`; for English the tokenizer is closer to 1 word/token.
- When TTFW is under ~0.5 s, container and router overhead is measurable. Report it, don't subtract it: end-to-end TTFW is the production metric.
