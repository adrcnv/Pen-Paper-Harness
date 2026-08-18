require "stringio"

module Harness
  module Driver
    # Headless play session — the programmatic twin of bin/play. One Session
    # owns a Context, a Scene::Manager, and a Turn::Loop against the SCENARIO
    # database (RAILS_ENV=scenario; guarded — it refuses to run against the
    # development save). Consumers: the MCP tester wrapper, the scenario
    # recorder, and the nightly runner.
    #
    # No TTY anywhere: scene-change confirmations auto-approve, character
    # creation is mechanical (standard array, first-option ability picks),
    # and turn seeds derive from the session seed so a run is reproducible
    # end to end.
    class Session
      STANDARD_ARRAY = { strength: 15, dexterity: 14, constitution: 13,
                         intelligence: 12, wisdom: 10, charisma: 8 }.freeze

      attr_reader :context, :player, :logger

      # grunt:/nuance: accept prebuilt adapters (tests inject stubs); nil
      # builds from ENV exactly like bin/play (HARNESS_BACKEND etc.).
      def initialize(seed: Random.new_seed, snapshot_dir: nil, logger: Rails.logger,
                     grunt: nil, nuance: nil)
        guard_environment!
        @seed      = seed
        @turn_rng  = Random.new(seed)
        @logger    = logger
        @nuance    = nuance || build_adapter(ENV["HARNESS_NUANCE_MODEL"] || default_model, :nuance)
        @grunt     = grunt  || (ENV["HARNESS_GRUNT_MODEL"] ? build_adapter(ENV["HARNESS_GRUNT_MODEL"], :grunt) : @nuance)
        @snapshot_dir = snapshot_dir
        ::Harness::Timing.enable!
        ::Harness::Turn::Receipt.enable!
      end

      # Wipe the scenario DB and generate a fresh world + a mechanical player.
      def new_world!(name: "Tester", character_class: "fighter", cities: nil, kingdoms: nil)
        wipe_db!
        opts = { seed: @seed, llm: @grunt, logger: @logger }
        opts[:city_count]    = cities   if cities
        opts[:kingdom_count] = kingdoms if kingdoms
        ::Harness::Worldgen::Pipeline.run!(**opts)

        city = ::Location.where(parent_id: nil).where.not(x: nil, y: nil)
                         .where.not(faction_id: nil).to_a.sample(random: @turn_rng)
        raise "worldgen produced no spawn city" unless city

        @player = ::Player.create!(
          name: name, location: city, character_class: character_class,
          level: 1, **STANDARD_ARRAY
        )
        ::Harness::Character::Hatchery.materialize!(@player, llm_grunt: @grunt)
        drain_ability_picks!
        boot!
      end

      # Attach to whatever already lives in the scenario DB.
      def continue!
        @player = ::Player.first
        raise "no player in the scenario DB — use new_world! first" unless @player&.location
        boot!
      end

      # One turn. Returns what a player would see plus the flight recorder.
      def play(input)
        raise "session not booted — new_world! or continue! first" unless @loop
        transcript = @loop.run_turn(input: input, seed: @turn_rng.rand(2**31))
        {
          "narration" => transcript.narration,
          "notice"    => transcript.notice,
          "halted"    => transcript.halted ? true : false,
          "game_time" => @context.game_time,
          "location"  => @context.player_location&.name,
          "receipt"   => ::Harness::Turn::Receipt.last
        }
      end

      def game_time      = @context&.game_time
      def player_location = @context&.player_location

      private

      # The whole point of the scenario env. A session against the play save
      # is a bug, full stop. Test env is allowed so specs can exercise this
      # class.
      def guard_environment!
        return if ::Rails.env.scenario? || ::Rails.env.test?
        raise "Driver::Session requires RAILS_ENV=scenario (got #{::Rails.env}) — it must never run against the play save"
      end

      def boot!
        @context = ::Harness::Turn::Context.new(
          player_location: @player.location,
          llm_grunt:       @grunt,
          llm_nuance:      @nuance,
          game_time:       [ ::Event.maximum(:game_time) || 0, 100_000 ].max
        )
        @context.confirm_scene_change = ->(_dest) { true } # headless: never block
        @scene_manager = ::Harness::Scene::Manager.new(context: @context, logger: @logger)
        @loop = ::Harness::Turn::Loop.new(
          adapter:       @nuance,
          context:       @context,
          snapshot_dir:  @snapshot_dir,
          scene_manager: @scene_manager,
          logger:        @logger
        )
        @loop.baseline_snapshot! if @snapshot_dir
        self
      end

      # First-option picks, deterministically. The picker reads numbered
      # choices from io; an endless stream of "1" always resolves.
      def drain_ability_picks!
        ones = StringIO.new("1\n" * 32)
        ::Harness::Abilities::Picker.drain_pending!(@player.reload, io: ones, out: StringIO.new, logger: @logger)
        ::Harness::Items::Inventory.roll_for_player(@player) unless @player.items.exists?
      end

      def wipe_db!
        conn = ::ActiveRecord::Base.connection
        conn.transaction do
          conn.execute("PRAGMA defer_foreign_keys = ON")
          conn.tables.each do |t|
            next if %w[ar_internal_metadata schema_migrations].include?(t)
            conn.execute("DELETE FROM #{conn.quote_table_name(t)}")
          end
          begin
            conn.execute("DELETE FROM sqlite_sequence")
          rescue ::StandardError
            nil
          end
        end
      end

      def default_model
        (ENV["HARNESS_BACKEND"] || "anthropic").downcase == "anthropic" ? "claude-sonnet-4-6" : (ENV["HARNESS_OPENAI_MODEL"] || "local")
      end

      def build_adapter(model_name, name)
        case (ENV["HARNESS_BACKEND"] || "anthropic").downcase
        when "anthropic"
          ::Harness::LLM::AnthropicAdapter.new(
            api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: model_name, logger: @logger, name: name
          )
        when "openai-compat", "openai_compat", "local"
          ::Harness::LLM::OpenAICompatAdapter.new(
            base_url: ENV["HARNESS_OPENAI_BASE_URL"] || "http://127.0.0.1:8080/v1",
            api_key:  ENV["HARNESS_OPENAI_API_KEY"]  || "local",
            model:    model_name, logger: @logger, name: name
          )
        else
          raise "unknown HARNESS_BACKEND=#{ENV['HARNESS_BACKEND'].inspect}"
        end
      end
    end
  end
end
