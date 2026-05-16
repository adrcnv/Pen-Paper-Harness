module Harness
  module Abilities
    # Assigns a set of abilities to a character based on their class + level.
    # Pure mechanical: no LLM, no prompts, no materializer retries. Picks
    # uniformly at random from the eligible pool, capped at the available
    # set's size.
    #
    # Slot count: level + 1. Level 1 = 2 abilities (basic attack + utility,
    # so a level-1 mage actually has a spell), level 5 = 6, level 12 = 13,
    # level 20 = 21. The eligible-pool size is a hard ceiling: each class's
    # library entries cap around 6, so at level 5+ characters effectively
    # know all the abilities they qualify for. This matches the intent —
    # magical classes need their core attack-spell from turn one or they
    # can't function as a magical class.
    #
    # Idempotent? No — each call re-rolls. Hatchery calls this exactly once
    # at character creation. Re-rolling on every call would defeat persistence.
    # If a future tool wants to re-tier (level-up, retraining), call
    # explicitly.
    module Assigner
      class << self
        # Picks abilities for `character` (must have :character_class and
        # :level). Writes the array of ability hashes to character.abilities
        # (the existing JSON column). Returns the saved character.
        #
        # NPC rows: random pick from eligible pool, deterministic given rng.
        #
        # Player rows: DEFERS the picks via properties.pending_ability_picks
        # so the player chooses through Abilities::Picker rather than being
        # handed random spells. The counter equals slot_count_for(level)
        # (level 1 = 2 picks). bin/play drains the counter before turn 1
        # via Picker.drain_pending!. Idempotent — re-running on a Player
        # that already has abilities is a no-op.
        def assign!(character, rng: Random.new)
          if character.is_a?(::Player)
            return character if Array(character.abilities).any?
            slots = slot_count_for(character.level)
            props = (character.properties || {}).dup
            props["pending_ability_picks"] = slots
            character.update!(abilities: [], properties: props)
            return character
          end

          slots = slot_count_for(character.level)
          eligible = Library.for_class(character.character_class, max_level: character.level)

          pick_count = [ slots, eligible.size ].min
          chosen = eligible.sample(pick_count, random: rng).map { |a| with_runtime_state(a) }
          character.update!(abilities: chosen)
          character
        end

        # Each assigned ability carries its own `uses_remaining` counter,
        # initialized to the library entry's `uses_per_rest`. Resolve
        # decrements on use; pass_time(rest|sleep) refreshes the player's
        # counters back to the library values. Stored on the per-character
        # ability hash so each character tracks independently — a level-12
        # mage with two copies of Frost Sphere has two separate counters
        # only if she has two separate abilities (we don't currently
        # support duplicates, but the data model would).
        def with_runtime_state(library_row)
          library_row.merge("uses_remaining" => library_row["uses_per_rest"])
        end

        # level + 1 — level 1 gets 2 (basic attack + utility), level N gets
        # N+1. The eligible-pool size caps the actual count well below this
        # at higher levels.
        def slot_count_for(level)
          level.to_i + 1
        end
      end
    end
  end
end
