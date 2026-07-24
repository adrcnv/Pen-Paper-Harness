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
        maybe_lay_out_settlement(loc)
        maybe_run_catch_up(loc)
        maybe_run_materialize(loc, materialize_target)
        maybe_pull_traveler(loc)
        maybe_draw_local(loc)
        maybe_seed_location_items(loc)
        maybe_stock_shop(loc)
        maybe_seed_treasure(loc)

        snapshot = ::Harness::Scene::Assembler.for(location: loc)
        maybe_run_character_catch_up(snapshot.present_characters)
        maybe_weave_claim_web(snapshot.present_characters)
        flavor = generate_internal_state(loc, snapshot.present_characters)

        @active = Active.new(
          location:             loc,
          snapshot:             snapshot,
          narrations:           [],
          internal_state:       flavor[:internal_state],
          agendas:              flavor[:agendas],
          extras:               flavor[:extras],
          entered_at_game_time: @context.game_time || 0,
          # Initiative arrival-settle (nil = skip one turn) applies to ARRIVALS
          # only. An in-place rebuild — pass_time crossing the threshold at the
          # same location — is not an arrival: the player never left, and
          # re-arming the settle there muted initiative on exactly the turns
          # where hours just passed (chained time-skips kept it settled
          # forever). Same-location re-entry starts past the settle.
          initiative_cooldown:  (loc.id == @last_exit_location_id ? 0 : nil)
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

        # Remember who was on stage as the player leaves — the next enter's
        # draws exclude them (anti-cart: the NPC you just talked to must not
        # be re-drawn into the next scene behind you). Stamped with the clock:
        # the exclusion only holds within the SAME day-phase (see
        # cart_exclusions) — once the phase ticks over, people legitimately
        # relocate (the smith off-shift CAN be at the pub you walked to).
        @last_cast_ids       = ::Npc.where(location_id: @active.location.id).pluck(:id)
        @last_exit_game_time = @context.game_time
        @last_exit_location_id = @active.location.id

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

      # Adopt an externally rebuilt Active (session-state resume, replay-rig
      # rewind) WITHOUT running the enter chain — no genesis, no draws, no
      # internal-state calls. Pass nil to clear (restored between scenes).
      def restore(active)
        @active = active
        @context.active_scene = active
        active
      end

      private

      # Increment-2 social web: a claimed person present here (just placed, or
      # active since claim time) gets a few local NPCs who KNOW them, so asking
      # around at the destination points to them. Mechanical — reads the carried
      # gist, invents no identity. After the snapshot so present NPCs are known.
      def maybe_weave_claim_web(present_characters)
        ::Harness::NarrativeShift::SocialWeb.weave!(present_characters, @context, logger: logger)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] claim social-web failed: #{e.class}: #{e.message}" }
      end

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
        ::Harness::Scene::TravelerPull.maybe_pull(
          loc,
          exclude_ids: cart_exclusions, game_time: @context.game_time,
          rng: @rng, logger: logger
        )
      rescue StandardError => e
        logger.warn { "[Scene::Manager] traveler pull failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # The previous scene's cast, excludable ONLY while it still reads as
      # "you just left them there": same day-phase and recent. A phase
      # boundary (or a long absence) clears it — people move between blocks,
      # and a re-encounter after the shift change is a feature, not the cart.
      # A flat stand-in for real NPC routines; dies when those land.
      CART_WINDOW_MINUTES = 360

      def cart_exclusions
        return [] if Array(@last_cast_ids).empty? || @last_exit_game_time.nil?
        now = @context.game_time || 0
        return [] unless ::Harness::Clock.phase(now) == ::Harness::Clock.phase(@last_exit_game_time)
        return [] unless (now - @last_exit_game_time) < CART_WINDOW_MINUTES
        @last_cast_ids
      end

      # Intra-city draw: at a sublocation, occasionally a same-city resident
      # drifts in so the place feels connected to its town (Scene::LocalDraw).
      # Self-gates to sublocations — a no-op at the city tier, where residents
      # are already present. Pure relocation of an existing row (no LLM, no
      # spawn) but gated on llm_grunt like the other rich-assembly steps so
      # headless/no-LLM contexts stay deterministic.
      def maybe_draw_local(loc)
        return unless @context.llm_grunt
        ::Harness::Scene::LocalDraw.maybe_draw(
          loc,
          exclude_ids: cart_exclusions, game_time: @context.game_time,
          rng: @rng, logger: logger
        )
      rescue StandardError => e
        logger.warn { "[Scene::Manager] local draw failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Lay out a worldgen city's KNOWN SHAPE on entry — create the manifest's
      # sublocations (the docks, the smithy, the moot hall…) as child stubs, so
      # the town is legible structure to navigate rather than something the
      # player squeezes for "is there a smith?". Pure mechanical (no LLM gate),
      # idempotent via the city's `settlement_laid_out` flag. Only fires at the
      # top-level city tier with a profile; sublocations/wilderness/fixtures are
      # left to the existing lazy paths. Contents fill on approach (Materializer
      # reads each stub's name+description). Failure non-fatal.
      def maybe_lay_out_settlement(loc)
        return unless loc.parent_id.nil? && loc.x.present? && loc.y.present?
        return if loc.properties.is_a?(Hash) && loc.properties["kind"] == "wilderness_leaf"

        ::Harness::Settlement::Layout.lay_out!(city: loc, rng: @rng, logger: logger)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] settlement layout failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Stock a shop sublocation with wares on first entry (manifest stamped
      # `shop` categories on the stub). Pure mechanical, idempotent via
      # `shop_stocked`. No-op for non-shop locations. Failure non-fatal.
      def maybe_stock_shop(loc)
        return unless loc.properties.is_a?(Hash) && loc.properties["shop"].present?
        ::Harness::Economy::ShopStock.stock!(loc, rng: @rng, logger: logger)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] shop stocking failed for #{loc.name}: #{e.class}: #{e.message}" }
      end

      # Place a treasure chest on first entry to a location that warrants one
      # (bandit hideout, discovery site). Pure mechanical, idempotent via
      # `treasure_seeded`. Additive to scattered floor-loot. Failure non-fatal.
      def maybe_seed_treasure(loc)
        ::Harness::Treasure::Seeder.seed!(loc, rng: @rng, logger: logger)
      rescue StandardError => e
        logger.warn { "[Scene::Manager] treasure seeding failed for #{loc.name}: #{e.class}: #{e.message}" }
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

        if loc.properties.is_a?(Hash) && loc.properties["kind"] == "wilderness_leaf"
          # Wilderness leaves get NO materialized resident cast — they're
          # transient encounter spots, not settlements. Staffing them spawned
          # homeless rows in the middle of nowhere (a "lost_traveler" with no
          # home that the Evictor then culls). Wilderness population comes from
          # the LLM's ambient `extras` (materialized on engagement via
          # propose_character(from_extra:)) and the travel encounter-spawner.
          nil
        elsif loc.parent_id
          TARGET_COUNT_DISTRIBUTION.sample(random: @rng)
        else
          # Worldgen top-level city. Genesis spawned dormant rows for every
          # named historical in the backstory cluster; the Materializer
          # selects which to wake (founders still alive, the missing courier
          # who never returned, etc) and fills remaining slots with fresh
          # public-facing locals (a town crier, a guardsman, an old merchant).
          TARGET_COUNT_DISTRIBUTION.sample(random: @rng)
        end
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
