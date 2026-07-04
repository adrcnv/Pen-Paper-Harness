# Harness

A solo tabletop-RPG engine. The simulation owns ground truth; the LLM
translates between your input and validated tool calls.

> **Status:** personal exploratory project — a sandbox with rough edges and
> half-built subsystems.

## Requirements

- Ruby 3.4.9 (pinned in `.ruby-version` / `mise.toml`; use [mise](https://mise.jdx.dev/))
- SQLite 3
- An LLM provider — either Anthropic Claude (cloud, needs `ANTHROPIC_API_KEY`)
  or any OpenAI-compatible endpoint (llama.cpp `llama-server`, vLLM, Ollama, …)

## Quick start

```bash
git clone <this repo>
cd Harness

# Installs gems, copies .env.example -> .env, runs migrations. Idempotent.
bin/setup

# Paste your ANTHROPIC_API_KEY (or wire up a local endpoint).
$EDITOR .env

bin/play
```

Pass `--reset` to `bin/setup` or `bin/play` to wipe and rebuild the database.

## Playing

`bin/play` is the REPL. First run prompts for character creation and seeds a
fresh world; later runs continue the save.

```bash
bin/play                                    # continue, or start a new game
bin/play --reset                            # wipe DB and start fresh
bin/play --model claude-opus-4-8
bin/play --grunt-model claude-haiku-4-5-20251001 \
         --nuance-model claude-sonnet-5
```

Two model tiers: a cheap grunt-tier for materialization (NPC stats, scene
flavor, catch-up) and a stronger nuance-tier for the reasoning loop and
narration.

## Local inference

The OpenAI-compatible adapter targets any server speaking
`/v1/chat/completions`. Pointed at llama.cpp's `llama-server` running a local
quant (Qwen 3.6 35B-A3B is the daily driver), the whole game runs offline.

```bash
# llama.cpp default endpoint is also the default base URL, so
# HARNESS_OPENAI_BASE_URL can be omitted here.
HARNESS_BACKEND=openai-compat \
HARNESS_OPENAI_BASE_URL=http://127.0.0.1:8080/v1 \
bin/play
```

Knowledge recall ranks facts by embedding similarity against the same server,
so launch `llama-server` with embeddings enabled:

```bash
llama-server -m <model.gguf> --embeddings --pooling mean
```

Completions and embeddings coexist on the one instance (no VRAM split). If
embeddings are unavailable the ranker falls back to recency — recall still
works, just less semantically.

See `lib/harness/llm/openai_compat_adapter.rb` for the configuration surface.

## Tests

```bash
bundle exec rspec
```

Runs against a real SQLite database with a stub LLM adapter. ~1600 examples,
a few seconds.
