# OMNIX Provider Matrix

Last reviewed: 2026-09-08

This document is a maintenance record, not a permanent pricing promise. Cloud providers can change models, quotas, regions, free tiers and data policies at any time. OMNIX therefore loads model lists dynamically where the provider supports it and surfaces rate-limit/provider errors rather than silently falling back to a paid model.

| Provider | OMNIX ID | Type | API key | Free / local status | Default | Vision in OMNIX | Official setup/docs |
|---|---|---|---|---|---|---|---|
| Ollama | `ollama` | Local | No | Local; no cloud token billing | first detected local model | Model-dependent | https://docs.ollama.com/ |
| LM Studio | `lmstudio` | Local | No | Local; no cloud token billing | loaded local model | Model-dependent | https://lmstudio.ai/docs |
| Google Gemini | `gemini` | Cloud | Yes | Free tier currently available for supported models; limits/region apply | `gemini-3.8-flash` | Yes | https://ai.google.dev/gemini-api/docs / https://aistudio.google.com/apikey |
| Groq | `groq` | Cloud | Yes | Free Plan currently published with model-specific limits | `openai/gpt-oss-120b` | Model-dependent | https://console.groq.com/docs/quickstart / https://console.groq.com/keys |
| OpenRouter | `openrouter` | Cloud | Yes | `openrouter/free` + live `:free` variants | `openrouter/free` | Model-dependent; free router supports capability routing | https://openrouter.ai/docs / https://openrouter.ai/settings/keys |
| Mistral AI | `mistral` | Cloud | Yes | Studio Free mode currently available with limited usage/rate limits | `mistral-small-latest` | Model-dependent | https://docs.mistral.ai/getting-started/quickstarts/developer/first-api-request / https://console.mistral.ai/ |
| Cerebras | `cerebras` | Cloud | Yes | $0 Free tier currently documented with lower model-specific limits | `gpt-oss-120b` | Text-only in this OMNIX build | https://inference-docs.cerebras.ai/quickstart / https://cloud.cerebras.ai/ |
| Custom OpenAI-compatible | `custom` | User endpoint | Optional | Defined entirely by endpoint owner | user configured | Probe-dependent | User configured; OMNIX does not invent a setup URL |

## Free-first behavior

- Local AI is preferred when `Prefer Local AI when available` is enabled and a compatible local model is reachable.
- `Local Only` privacy mode blocks cloud sends.
- OpenRouter model discovery places `openrouter/free` first, then currently detected zero-price / `:free` model ids, then other models.
- OMNIX does not automatically convert a provider failure into a paid request.
- Cloud free-tier labels are informational. A `429` remains a quota/rate-limit error; a provider-policy failure remains a provider/privacy error.

## Secrets and privacy

- API keys are stored with Windows DPAPI (`CurrentUser`) and are not logged.
- Cloud sends are subject to OMNIX Privacy Mode before the provider call.
- Official setup links exposed by Settings are HTTPS and restricted to a hard-coded provider-owned host allowlist.
- Custom provider URLs are user configuration and are not opened as trusted setup links by OMNIX.

## Runtime release gate

Provider code compiling is not enough for release. Before OMNIX v3 is considered complete, test at least:

1. API-key save/reload without plaintext leakage.
2. Load Models against each configured cloud provider.
3. Text streaming round-trip.
4. Correct `401/403`, `429`, timeout and provider-policy error classification.
5. Vision request on a Vision-capable provider/model.
6. Local-only request with the Internet disconnected and a local model running.
7. OpenRouter `openrouter/free` request and at least one live `:free` model when available.

Do not mark an unexecuted provider test PASS.
