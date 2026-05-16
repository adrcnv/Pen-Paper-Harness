module Harness
  module Character
    # Single seam for character creation. Replaces scattered Npc.create! /
    # Npc.find_or_create_by! calls across Genesis, Scene::Materializer,
    # Tools::ProposeCharacter, Scene::PendingAppearanceResolver, and
    # CatchUp::Generator. Every fresh character gets a level + six stats
    # materialized at creation time, conditioned on the prose context the
    # caller hands over.
    #
    # The lazy fallback (Stats::Materializer#materialize_if_needed on first
    # resolve) is preserved as a safety net — any character that slipped
    # past this seam still gets stats eventually — but the eager path is
    # the primary. With local inference, eager doesn't burn the token
    # budget that originally motivated the lazy design.
    #
    # Scenario seed (the outlier-injection from character_creation.yml) is
    # rolled per spawn. ~92% of rolls fire `nothing_interesting` (no seed
    # appended); the remaining rolls inject an outlier scenario the
    # materializer reads as override of the apparent subrole's baseline.
    module Hatchery
      SCENARIO_TABLE = "character_creation"

      class << self
        # Create a fresh character row and materialize stats + level. Always
        # returns a saved record. Callers pass any subset of model attrs
        # (name, subrole, location_id, properties, etc).
        #
        # llm_grunt: when nil (test contexts, dry runs), falls back to
        # baseline defaults — level 1, all stats DEFAULT_STAT_VALUE — so
        # the row is still valid for resolve. A future stat-aware test
        # can opt into materialization explicitly.
        #
        # prose_context: optional freeform string (event narratives, the
        # spawning prompt's reasoning, an appearance_intent). Routed to
        # the materializer's user message.
        #
        # dormant: when true, sets properties.dormant = true so the row is
        # excluded from present_characters / recent_actors until something
        # wakes it (Scene::Materializer or an explicit relocation). Used
        # by Genesis for named historicals from backstory events — they
        # exist structurally (so event_participants can FK to them) but
        # don't crowd the scene at the genesis location until the player
        # arrives and the materializer picks them.
        #
        # rng: dependency-injected for deterministic tests of scenario
        # rolling.
        def spawn(llm_grunt:, type: ::Npc, prose_context: nil, rng: Random.new, dormant: false, **attrs)
          attrs = inject_encounter_intent(attrs, rng: rng) unless type == ::Player
          attrs = inject_dormant(attrs)                     if dormant
          char  = type.create!(**attrs)
          materialize!(char, llm_grunt: llm_grunt, prose_context: prose_context, rng: rng)
          char
        end

        # Find by `find_attrs` or spawn fresh. When found, returns the
        # existing row untouched — does NOT re-materialize stats. When
        # spawning, applies `spawn_attrs` (defaults to `find_attrs`) plus
        # any extras and materializes. Use this from callers that
        # idempotently re-encounter the same character (genesis,
        # catch-up).
        def find_or_spawn(llm_grunt:, type: ::Npc, find_attrs:, spawn_attrs: nil, prose_context: nil, rng: Random.new, **rest)
          existing = type.find_by(find_attrs)
          return existing if existing

          merged = (spawn_attrs || find_attrs).merge(rest)
          spawn(llm_grunt: llm_grunt, type: type, prose_context: prose_context, rng: rng, **merged)
        end

        # Apply full materialization (stats + level THEN personality +
        # appearance) to an existing character. Two sequential LLM calls;
        # description is downstream of stats by design — a STR-17 character
        # looks broad-shouldered, a level-12 retired-archmage barkeep has
        # one detail wrong for the cover. The description call sees the
        # just-rolled stats and the same scenario seed.
        #
        # Description failure is non-fatal — stats are the load-bearing
        # output (resolve depends on them), description is flavor. If the
        # description call raises after retries, the character keeps the
        # stats and we move on without a personality/appearance entry.
        def materialize!(character, llm_grunt:, prose_context: nil, rng: Random.new)
          # Player path: stats/class/level were hand-set by CharacterCreation.
          # Skip the LLM materializers entirely; just run the mechanical
          # steps (abilities + HP) so the player has a full ability list
          # and computed max HP from turn 1.
          if character.is_a?(::Player)
            ::Harness::Abilities::Assigner.assign!(character, rng: rng)
            ::Harness::Character::HP.apply!(character)
            roll_inventory_if_empty(character, rng: rng)
            return character
          end

          if llm_grunt.nil?
            apply_defaults(character)
            roll_inventory_if_empty(character, rng: rng)
            return character
          end

          scenario_seed = roll_scenario(rng: rng)

          begin
            ::Harness::Stats::Materializer
              .new(llm_client: llm_grunt)
              .materialize!(character, prose_context: prose_context, scenario_seed: scenario_seed)
          rescue StandardError => e
            ::Rails.logger.warn { "[Character::Hatchery] stat materialization failed for #{character.name}: #{e.class}: #{e.message}; falling back to defaults" }
            apply_defaults(character)
            roll_inventory_if_empty(character, rng: rng)
            return character
          end

          # Stats are now committed on the row. Description sees them.
          begin
            ::Harness::Description::Materializer
              .new(llm_client: llm_grunt)
              .materialize!(character, prose_context: prose_context, scenario_seed: scenario_seed)
          rescue StandardError => e
            ::Rails.logger.warn { "[Character::Hatchery] description materialization failed for #{character.name}: #{e.class}: #{e.message}; character keeps stats but no personality/appearance" }
          end

          # Abilities: pure mechanical assignment from the static library.
          # No LLM call, no failure path worth catching — Library.for_class
          # returns an array, sample is deterministic given rng. Runs after
          # stats so character_class + level are on the row.
          ::Harness::Abilities::Assigner.assign!(character, rng: rng)

          # HP: derived from class hit_die + level + CON. Runs after
          # abilities because it needs character_class, level, and
          # constitution all set.
          ::Harness::Character::HP.apply!(character)

          # Interpretation lens: weighted random roll, set once. Drives
          # belief projection bias — a cynic projects neutral events as
          # suspect; a romantic projects them as warmer. ~50% land on
          # `balanced` (neutral); the named lenses are minority colors.
          # No LLM call; pure mechanical assignment from the distribution.
          ::Harness::Character::Lens.apply!(character, rng: rng)

          # Inventory: pure mechanical roll from the class table. No LLM
          # call. Most NPCs roll `nothing` (commoners ~70%, fighters ~5%);
          # a small fraction hits `legendary_outlier` for the "randomly
          # rich people for no reason" flavor. Idempotent on re-spawn —
          # only fires when the character has zero items.
          roll_inventory_if_empty(character, rng: rng)

          character
        end

        private

        # Set properties.dormant = true on the attrs hash. Existing
        # properties are preserved; dormant just adds to them.
        def inject_dormant(attrs)
          props = (attrs[:properties] || {}).dup
          props["dormant"] = true
          attrs.merge(properties: props)
        end

        # When spawning at a wilderness_leaf with a populated
        # `encounter_type`, merge the matching role_intent into the
        # character's properties so the agenda generator at scene entry
        # has something concrete to ground in (fresh encounter NPCs have
        # NO past events, so without this they get no agenda). Bias
        # subrole only when the caller didn't already pass one — the
        # reasoning loop's propose_character path passes one explicitly.
        # No-op for non-encounter locations or unknown encounter_types.
        def inject_encounter_intent(attrs, rng:)
          loc_id = attrs[:location_id] || attrs[:location]&.id
          return attrs unless loc_id
          loc = ::Location.find_by(id: loc_id)
          return attrs unless loc&.properties.is_a?(Hash)
          etype = loc.properties["encounter_type"]
          return attrs unless etype
          intent = ::Harness::Encounters::RoleIntent.for(etype)
          return attrs unless intent

          props = (attrs[:properties] || {}).dup
          props["role_intent"] ||= intent[:role_intent]
          attrs = attrs.merge(properties: props)

          if attrs[:subrole].nil? || attrs[:subrole].to_s.strip.empty?
            attrs = attrs.merge(subrole: intent[:subrole_bias].sample(random: rng))
          end

          attrs
        end

        # Idempotent: skip if the character already owns items, so
        # re-running materialize! on an existing row doesn't double-stock.
        # Failures are non-fatal — log and move on; the row is still
        # valid for play, just inventory-less.
        def roll_inventory_if_empty(character, rng:)
          return if character.items.exists?
          if character.is_a?(::Player)
            ::Harness::Items::Inventory.roll_for_player(character, rng: rng)
          else
            ::Harness::Items::Inventory.roll_for_npc(character, rng: rng)
          end
        rescue StandardError => e
          ::Rails.logger.warn { "[Character::Hatchery] inventory roll failed for #{character.name}: #{e.class}: #{e.message}" }
        end

        def apply_defaults(character)
          attrs = ::Character::STATS.each_with_object({}) { |s, h| h[s.to_sym] = ::Character::DEFAULT_STAT_VALUE }
          attrs[:level]           = ::Character::DEFAULT_LEVEL
          attrs[:character_class] = "commoner"
          attrs[:abilities]       = []
          character.update!(attrs)
          ::Harness::Character::HP.apply!(character)
          ::Harness::Character::Lens.apply!(character)
          character
        end

        def roll_scenario(rng:)
          ::Harness::Scenarios::Roller.roll(table: SCENARIO_TABLE, context: {}, rng: rng).prompt_seed
        end
      end
    end
  end
end
