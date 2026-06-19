module Harness
  module Scene
    # Orchestrates the per-scene lifecycle: enter (assemble structural
    # snapshot, optionally materialize fresh characters) and exit (mechanical
    # witness backfill). Owns the active Scene state for the turn loop.
    #
    # Scope this slice:
    #   - enter: assembler runs unconditionally; materializer is currently
    #     opt-in via `materialize_target:` arg (default nil = skip).
    #   - exit: WitnessTagger runs against events committed at this scene's
    #     location during this scene's window. Pure SQL, no LLM.
    #   - InternalState (per-character mood prose) at scene entry.
    #
    # Genesis / CatchUp / CharacterCatchUp DO fire on entry — the deep-thesis
    # behavior. Cost is real (~$0.10 + $0.05 + $0.05 per first-city entry); the
    # accepted tradeoff is that the world feels populated with history and
    # offscreen activity from turn 1. Skipped when no llm_grunt configured
    # (test contexts and dry runs). All three are content-budget-tuned: Genesis
    # 1-2 events, CatchUp 0-1, CharacterCatchUp 0-1 per character.
    #
    # The manager is constructed once per Turn::Loop and threads the
    # context through. `llm_grunt` powers internal-state, materializer,
    # genesis, and catch-up. Scene exit no longer needs an LLM.
    class Manager
      # Auto-target distribution for fresh sublocations: heavy bias toward 3,
      # tail to 6. Picks the floor for a "this place should feel inhabited"
      # check at scene entry. Tuned with the user; do not raise the ceiling
      # without revisiting LLM cost — every fresh sublocation entry is one
      # Materializer call.
      TARGET_COUNT_DISTRIBUTION = (
        [ 3 ] * 50 + [ 4 ] * 30 + [ 5 ] * 15 + [ 6 ] * 5
      ).freeze

      # Wilderness leaves (player-proposed wayshrines, encounter-spawned
      # bandit camps later, etc.) get a tighter cast — these are not "regular
      # cast" places like a tavern or a customs office.
      WILDERNESS_TARGET_DISTRIBUTION = (
        [ 2 ] * 3 + [ 3 ] * 2 + [ 4 ]
      ).freeze

      attr_reader :logger, :active

      def initialize(context:, logger: Rails.logger, rng: Random.new)
        @context = context
        @logger  = logger
        @rng     = rng
        @active  = nil
      end

      # Idempotent — returns the existing active scene if already entered
      # at the same location. Use `force: true` to rebuild.
      def ensure_entered(materialize_target: nil, force: false)
        if @active && @active.location.id == @context.player_location.id && !force
          return @active
        end
        enter(materialize_target: materialize_target)
      end

      # Build a fresh active scene at context.player_location.
      def enter(materialize_target: nil)
        loc = @context.player_location
        logger.info { "[Scene::Manager] enter location=#{loc.name}" }

        maybe_run_genesis(loc)
        maybe_run_catch_up(loc)
        maybe_resolve_pending_appearances(loc)
        maybe_run_quest_generation(loc)
        maybe_run_materialize(loc, materialize_target)
        maybe_pull_traveler(loc)
        maybe_draw_local(loc)
        maybe_seed_location_items(loc)

        snapshot = ::Harness::Scene::Assembler.for(location: loc)
        maybe_run_character_catch_up(snapshot.present_characters)
        flavor = generate_internal_state(loc, snapshot.present_characters)

        @active = Active.new(
          location:             loc,
          snapshot:             snapshot,
          narrations:           [],
          internal_state:       flavor[:internal_state],
          agendas:              flavor[:agendas],
          extras:               flavor[:extras],
          entered_at_game_time: @context.game_time || 0
        )
        @context.active_scene = @active
        @active
      end

      # Mechanical witness backfill against events committed at this scene's
      # location during this scene's lifetime, then drop the active reference
      # so the next enter starts clean. The narration step does NOT invent
      # nouns — the reasoning loop owns all entity creation through tools, so
      # there's nothing for an LLM-driven extractor to clean up. The only
      # structural job at scene exit is "who silently witnessed what," which
      # is presence-during-window — pure SQL.
      def exit
        return nil unless @active

        added = ::Harness::Scene::WitnessTagger.tag(
          @active,
          @context.game_time || 0,
          logger: logger
        )

        # Clear non-residents from the scene we're leaving: transients go home,
        # pure-flavor strangers evaporate. Stops the "merchants stranded at the
        # crossing forever" pile-up.
        ::Harness::Scene::Evictor.evict!(@active.location, logger: logger)

        @active = nil
        @context.active_scene = nil
        added
      end

      def record_narration(input, narration)
        @active&.append_narration(input, narration)
      end

      private

      # Genesis-on-entry: when the player first enters a worldgen-rooted city
      # that has no events yet, generate a small cluster of past events to
      # give the place a felt history. Skipped for:
      #   - sublocations (their history IS the parent's)
      #   - wilderness_leafs (player-proposed and encounter-spawned alike —
      #     ephemeral places, not worth back-generating texture for)
      #   - already-populated locations (idempotent — events present means
      #     genesis already ran or play has accrued events)
      #   - test/dry-run setups without llm_grunt
      # Failure is non-fatal — scene entry continues even if genesis raises.
      # Genesis::Generator now materializes Characters at commit (post-class-2
      # collapse) so participants get real character_id rows.
      def maybe_run_genesis(loc)
        return unless @context.llm_grunt
        return unless loc.parent_id.nil? && loc.x.present? && loc.y.present?
        return if loc.properties.is_a?(Hash) && loc.properties["kind"] == "wilderness_leaf"
        return if ::Event.where(location_id: loc.id).exists?

        anchor = nearest_top_level_neighbor(loc)
        ::Harness::Genesis::Generator
          .new(llm_client: @context.llm_grunt, logger: logger)
          .generate(
            location:          loc,
            anchor:            anchor,
            current_game_time: @context.game_time || 0,
            connection:        nil
          )
      rescue StandardError => e
        logger.warn { "[Scene::Manager] genesis-on-entry failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Catch-up: fill in ambient events that happened HERE while the player
      # was elsewhere. Skipped for locations with no prior events (Genesis
      # territory or fresh sublocation), for short gaps (Generator's own
      # MIN_GAP check), and when llm_grunt isn't configured. Failure is
      # non-fatal. CatchUp::Generator now materializes Characters at commit.
      def maybe_run_catch_up(loc)
        return unless @context.llm_grunt

        ::Harness::CatchUp::Generator
          .new(llm_client: @context.llm_grunt, logger: logger)
          .generate(
            location:          loc,
            current_game_time: @context.game_time || 0
          )
      rescue StandardError => e
        logger.warn { "[Scene::Manager] catch-up failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Character catch-up: refresh present characters with 0-1 personal-scope
      # events describing what they were doing off-screen during the lookback
      # window. Skipped when no llm_grunt and when present_characters is
      # empty. Failure non-fatal.
      def maybe_run_character_catch_up(present_characters)
        return unless @context.llm_grunt
        return if present_characters.empty?

        ::Harness::Scene::CharacterCatchUp::Generator
          .new(llm_client: @context.llm_grunt, logger: logger)
          .generate(
            characters:        present_characters,
            current_game_time: @context.game_time || 0
          )
      rescue StandardError => e
        logger.warn { "[Scene::Manager] character catch-up failed: #{e.class}: #{e.message}" }
      end

      # Materialize characters into this location at scene entry. Two paths:
      #   - explicit `materialize_target` (test/debug call sites set this) — fires
      #     unconditionally to that count.
      #   - auto: when target is nil, fires only if this is a sublocation with
      #     ZERO NPCs anchored. Picks target from TARGET_COUNT_DISTRIBUTION
      #     (heavy bias to 3). Skipped for top-level locations and wilderness
      #     leaves (they don't have a "regular cast"), and for already-populated
      #     sublocations (re-entry doesn't repopulate — that's background-sim
      #     territory we don't have).
      # Failure non-fatal: scene entry continues even if Materializer raises
      # (matches the genesis / catch-up pattern). Worst case the player walks
      # into an empty room — same as the pre-fix state.
      def maybe_run_materialize(loc, materialize_target)
        return unless @context.llm_grunt

        target = materialize_target || auto_target_for(loc)
        return unless target

        ::Harness::Scene::Materializer
          .new(llm_client: @context.llm_grunt, logger: logger)
          .materialize(location: loc, target_count: target)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] auto-materialize failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Keep populated towns from freezing: occasionally a resident of another
      # city wanders in (Scene::TravelerPull). Pure relocation of an existing
      # row — no LLM, no spawn — but gated on llm_grunt like the other rich-
      # assembly steps, so headless/no-LLM contexts stay deterministic.
      def maybe_pull_traveler(loc)
        return unless @context.llm_grunt
        ::Harness::Scene::TravelerPull.maybe_pull(loc, rng: @rng, logger: logger)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] traveler pull failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Intra-city draw: at a sublocation, occasionally a same-city resident
      # drifts in so the place feels connected to its town (Scene::LocalDraw).
      # Self-gates to sublocations — a no-op at the city tier, where residents
      # are already present. Pure relocation of an existing row (no LLM, no
      # spawn) but gated on llm_grunt like the other rich-assembly steps so
      # headless/no-LLM contexts stay deterministic.
      def maybe_draw_local(loc)
        return unless @context.llm_grunt
        ::Harness::Scene::LocalDraw.maybe_draw(loc, rng: @rng, logger: logger)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] local draw failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Quest generation on first entry — debt-spreading per QUESTS_DESIGN.md.
      # The trigger is "first-time entry to a city or one of its sublocations,
      # while the city still has unspent quest_debt." Each fire authors ONE
      # complete quest (people + sublocations + items + a backward kickoff
      # event); the player discovers it later by talking to participants.
      # Skipped for:
      #   - locations without a top-level worldgen-rooted city in their chain
      #     (wilderness leaves, hand-authored fixture top-tiers).
      #   - locations already entered before (`properties.first_entered_at_game_time`).
      #   - quest-spawned sublocations themselves (would recurse pointlessly
      #     since the city's debt is the per-city count).
      #   - cities whose debt is fully paid (`quest_debt <= quest_generated_count`).
      #   - test/dry-run setups without llm_grunt.
      # Failure non-fatal — scene entry continues. The marking is done EVEN
      # on failure so we don't retry on every re-entry.
      def maybe_run_quest_generation(loc)
        return unless @context.llm_grunt
        return unless ::Harness::Quests.enabled?  # HARNESS_QUESTS=on gate

        # Always mark first-entry regardless of whether we fire. Stops infinite
        # retries on repeat entry to a location quest gen failed at.
        already_entered = loc.properties.is_a?(Hash) && loc.properties["first_entered_at_game_time"]
        mark_first_entry!(loc) unless already_entered
        return if already_entered

        # Don't recurse from quest-spawned sublocations.
        return if loc.properties.is_a?(Hash) && loc.properties["kind"] == "quest_sublocation"

        city = top_level_city_for(loc)
        return unless city

        city_props = city.properties || {}
        debt       = city_props["quest_debt"].to_i
        generated  = city_props["quest_generated_count"].to_i
        return if generated >= debt

        ::Harness::Quests::Generator
          .new(llm_client: @context.llm_grunt, logger: logger, rng: @rng)
          .generate(city: city, current_game_time: @context.game_time || 0)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] quest generation failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      def mark_first_entry!(loc)
        props = (loc.properties || {}).dup
        props["first_entered_at_game_time"] = @context.game_time || 0
        loc.update!(properties: props)
      end

      # Walk up to the nearest top-level (parent_id nil) ancestor with
      # worldgen coords. nil for hand-authored fixtures without a real city.
      def top_level_city_for(loc)
        current = loc
        while current
          if current.parent_id.nil? && current.x.present? && current.y.present?
            return current
          end
          current = current.parent
        end
        nil
      end

      # Seed anchored items at this location on first scene entry.
      # Pure mechanical roll, no LLM call. Idempotent — LocationSeeder
      # marks the location with `items_seeded: true` after firing, so
      # repeat entries (and even fully-looted-out locations) never
      # re-seed. Failure is non-fatal — same posture as the other
      # maybe_run_* hooks.
      def maybe_seed_location_items(loc)
        ::Harness::Items::LocationSeeder.seed!(loc, rng: @rng)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] location item seeding failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      def auto_target_for(loc)
        # "Already populated" = at least one ACTIVE (non-dormant) Npc here.
        # Genesis spawns dormant historicals at the city tier; they're row-shaped
        # placeholders, not inhabitants yet — the Materializer's job is to
        # wake the ones who plausibly fit and spawn fresh public-facing locals.
        any_active = ::Npc.where(location_id: loc.id).any? { |c|
          props = c.properties
          !(props.is_a?(Hash) && props["dormant"] == true)
        }
        return nil if any_active

        if loc.parent_id
          TARGET_COUNT_DISTRIBUTION.sample(random: @rng)
        elsif loc.properties.is_a?(Hash) && loc.properties["kind"] == "wilderness_leaf"
          WILDERNESS_TARGET_DISTRIBUTION.sample(random: @rng)
        else
          # Worldgen top-level city. Genesis spawned dormant rows for every
          # named historical in the backstory cluster; the Materializer
          # selects which to wake (founders still alive, the missing courier
          # who never returned, etc) and fills remaining slots with fresh
          # public-facing locals (a town crier, a guardsman, an old merchant).
          TARGET_COUNT_DISTRIBUTION.sample(random: @rng)
        end
      end

      # Pending-appearance resolution at scene entry. Strangers, debt
      # collectors, faction emissaries, and known characters who decided to
      # find the player all materialize into the scene here. Pure structural
      # — no LLM. Failure non-fatal: scene entry continues even if resolution
      # raises. Skipped when there's no Player row (test/worldgen contexts).
      def maybe_resolve_pending_appearances(loc)
        target = ::Player.first
        return unless target

        ::Harness::Scene::PendingAppearanceResolver
          .new(llm_grunt: @context.llm_grunt, logger: logger)
          .resolve(
            target_character:  target,
            current_location:  loc,
            current_game_time: @context.game_time || 0
          )
      rescue StandardError => e
        logger.warn { "[Scene::Manager] pending-appearance resolution failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Returns a hash {internal_state: {char_id => prose}, agendas: {char_id => text}, extras: [...]}.
      # Skipped (empty everything) when no llm_grunt or no present NPCs.
      # Failures bubble up — generation is allowed to fail with a typed
      # error; the loop's outer ensure catches and persists.
      def generate_internal_state(location, present_characters)
        return empty_flavor if @context.llm_grunt.nil?
        return empty_flavor if present_characters.empty?

        result = ::Harness::Scene::InternalState
          .new(llm_client: @context.llm_grunt, logger: logger)
          .generate(location: location, characters: present_characters)

        {
          internal_state: result.internal_state,
          agendas:        result.agendas,
          extras:         result.extras
        }
      end

      def empty_flavor
        { internal_state: {}, agendas: {}, extras: [] }
      end

      def nearest_top_level_neighbor(loc)
        candidates = ::Location.where(parent_id: nil)
                               .where.not(id: loc.id)
                               .where.not(x: nil, y: nil)
                               .to_a
        candidates.min_by { |c| Math.hypot(c.x - loc.x, c.y - loc.y) }
      end
    end
  end
end
