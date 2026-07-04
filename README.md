# Harness

1

> **Status:** personal exploratory project. Plays end-to-end against a real
> model, but it's a sandbox — expect rough edges, half-built subsystems, and
> opinionated design choices that may turn out to be wrong.

## Why

Most "AI Dungeon Master" prototypes are chat wrappers: the model hallucinates
the world, the player corrects it, the model overwrites itself, the fiction
drifts into mush. Harness flips the relationship — the simulation owns ground
truth, the LLM translates between human language and structured operations.

Three principles do most of the work:

- **The LLM proposes, the core disposes.** Every state change goes through a
  validated tool call. The model never invents numbers, never forces outcomes,
  never touches storage directly.
- **Narration is rendering, not invention.** A reasoning loop commits all
  facts via tools, then a separate narration step turns the committed outcome
  into prose. The narration step can't introduce new named characters,
  factions, places, items, or events — only sensory and emotional flourish.
- **The world is not trying to please you.** It is indifferent. Walk into a
  forest looking for treasure and you find whatever is actually there, which
  is probably nothing, or something that will kill you.

## How it works (one paragraph)

A turn assembles a scene from the current location and its sublocations
(which characters are present, their internal state, what items are anchored
here), feeds it to the reasoning loop along with your input, and lets the
LLM call tools — query state, resolve dice checks, mutate characters,
propose new entities, advance time, enter combat. When the loop finishes, a
narration step takes the committed outcome and writes 2–4 sentences of
prose. Combat is a state-machine sub-mode: Ruby drives turn order, the LLM
is the brain for each individual slot, and the player's input drives one
slot per turn.

## The world

Top-level locations (cities, wilderness leaves) sit on a 2D map with real
(x, y) coordinates and a terrain tag. Worldgen builds the map by sampling a
noise field for biome classification, dropping cities with poisson-disk
placement, partitioning kingdoms via voronoi, and naming everything with
per-culture phoneme pools. Sublocations (a specific tavern, a back alley,
the throne room) hang off their parent city by `parent_id` and don't carry
coordinates.

Travel between top-level locations runs through the `travel` tool, which
walks a cursor from the player's current anchor toward the destination in
steps. Per-step encounter dice can stop the journey early at a freshly
spawned wilderness leaf; passing close to a known location can snap the
cursor to it. Cost is geometric: distance × terrain multiplier × per-unit
minutes. The old graph-of-paths model was retired — there is no `paths`
table, no pathfinding, no precomputed edges. Two cities being "connected"
just means the cursor can walk from one to the other across the map.

Within a city, the `transition` tool handles sublocation movement
(parent / sibling / child) at a flat per-move cost.

## Requirements

- Ruby 3.4.9 (pinned in `.ruby-version` and `mise.toml`)
- SQLite 3 (system package)
- An LLM provider — one of:
  - Anthropic Claude (cloud) — needs `ANTHROPIC_API_KEY`
  - Any OpenAI-compatible endpoint (llama.cpp's `llama-server`, vLLM,
    Ollama's openai-compat shim, OpenAI proper, etc.)

Recommended toolchain: [mise](https://mise.jdx.dev/) for the Ruby pin.

## Quick start

```bash
git clone <this repo>
cd Harness

# Installs gems, copies .env.example -> .env, runs migrations.
bin/setup

# Edit .env and paste your ANTHROPIC_API_KEY (or wire up a local endpoint).
$EDITOR .env

# Start playing.
bin/play
```

`bin/setup` is idempotent — safe to re-run any time. Pass `--reset` to wipe
and rebuild the development database.

## Playing

`bin/play` is the REPL. First run prompts for character creation and seeds a
fresh world via worldgen; subsequent runs continue the existing save.

```bash
bin/play                  # continue existing save, or start a new game
bin/play --reset          # wipe DB and start fresh
bin/play --model claude-opus-4-7
bin/play --grunt-model claude-haiku-4-5-20251001 \
         --nuance-model claude-sonnet-4-6
```

Two model tiers are supported: a cheap grunt-tier for materialization work
(NPC stats, scene flavor, catch-up sim) and a stronger nuance-tier for the
reasoning loop and narration.

### Slash commands

At the `>` prompt:

| Command | What it does |
| --- | --- |
| `/scene` | Dump the engine view of the current scene |
| `/history` | Dump the conversation history |
| `/map` | Render the world map (worldgen-rooted saves) |
| `/quests` | List offered and active quests |
| `/debug character=<id>` | Dump a character row + properties |
| `/debug eventlog` | Show recent events from the log |
| `/debug elapsed` | Per-call LLM timing for the last turn |
| `/debug levelup` | Level up the player (fires the ability picker) |
| `/quit` | Exit cleanly |

## Local inference

The OpenAI-compatible adapter targets any server that speaks
`/v1/chat/completions`. Pointed at llama.cpp's `llama-server` running a local
quant (Qwen 3.6 35B-A3B has been the daily driver during development), the
whole game runs offline with zero API spend — at the cost of per-call latency.

```bash
# Example: llama.cpp default endpoint (which is also the default base URL,
# so HARNESS_OPENAI_BASE_URL can be omitted in this case).
HARNESS_BACKEND=openai-compat \
HARNESS_OPENAI_BASE_URL=http://127.0.0.1:8080/v1 \
bin/play
```

See `lib/harness/llm/openai_compat_adapter.rb` for the configuration surface
(reasoning mode, custom base URL, timeouts).

## Tests

```bash
bundle exec rspec
```

The suite hits a real SQLite database and exercises the full tool surface
against a stub LLM adapter. ~1200 examples; runs in a few seconds.

## Project layout

```
app/models/          ActiveRecord rows: Character, Faction, Item, Location, Event, ...
lib/harness/
  combat/            Combat sub-mode: state machine, NPC turn driver, narration
  event/             Forward / backward append pipes, contradiction validator
  llm/               Adapters (Anthropic native, OpenAI-compatible)
  quests/            Wholesale archetype library + structural fulfillment
  scene/             Assembler, materializer, manager, witness backfill
  tools/             Tool implementations the LLM calls (query/mutate/propose/resolve)
  turn/              The per-turn loop that orchestrates reasoning + narration
  worldgen/          Noise + poisson cities + voronoi kingdoms + paths
bin/play             The REPL driver
bin/setup            First-time setup
```
