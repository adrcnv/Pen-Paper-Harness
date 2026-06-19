require "json"

module Harness
  module Shadow
    # Builds a tight planner prompt, calls the planner model(s), parses the
    # plan, and returns a structured result. Executes nothing; mutates
    # nothing. See Harness::Shadow for why.
    #
    # Calls llm_grunt always. If llm_nuance is a DISTINCT adapter, calls it
    # too and labels the plans per tier — but that two-tier diff is for a
    # future HOSTED backend only (see Harness::Shadow). Local play is always
    # single-model: both tiers point at the same adapter and we call once,
    # labeled "shared".
    class Planner
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/shadow_planner.txt")
      RECENT_HISTORY_CAP = 4

      VALID_RUNNERS = %w[
        inspection movement conversation worldbuilding
        inventory dice time-skip combat meta agentic
      ].freeze

      def self.run(context:, scene_manager:, input:, logger: Rails.logger)
        new(input: input, logger: logger, context: context, scene_manager: scene_manager).run
      end

      # LIVE single-plan entry for the dispatcher. ONE model call (the session
      # model via llm_nuance, falling back to llm_grunt), no tier diffing —
      # that's diagnostic/hosting only. Returns the call_one shape plus the
      # world it planned against:
      #   { "model","duration_ms","raw","plan","parse_error","world" }
      def self.plan_for(context:, scene_manager:, input:, logger: Rails.logger)
        new(input: input, logger: logger, context: context, scene_manager: scene_manager).plan_single
      end

      def plan_single
        world   = @world || world_view
        user    = user_message(world)
        adapter = @context.llm_nuance || @context.llm_grunt
        call_one(adapter, user).merge("world" => world)
      end

      # Offline entry point for batch replay (bin/shadow_replay): the caller
      # supplies a pre-built world view + the adapters to plan with, so the
      # planner runs with NO live context and NO DB scene. Lets us replay the
      # historical inputs from execution_flows_observed.md through the planner
      # without playing the game.
      def self.run_offline(input:, world:, adapters_by_tier:, logger: Rails.logger)
        new(input: input, logger: logger, world: world, adapters_by_tier: adapters_by_tier).run
      end

      def initialize(input:, logger:, context: nil, scene_manager: nil, world: nil, adapters_by_tier: nil)
        @input            = input
        @logger           = logger
        @context          = context
        @scene_manager    = scene_manager
        @world            = world
        @adapters_by_tier = adapters_by_tier
      end

      def run
        world = @world || world_view
        user  = user_message(world)

        {
          "input" => @input,
          "world" => world,
          "plans" => call_models(user)
        }
      end

      private

      # Map tier => adapter, collapsing duplicates. Same physical adapter for
      # both tiers (local single-model) → one entry labeled "shared".
      def adapters_by_tier
        return @adapters_by_tier if @adapters_by_tier
        grunt  = @context.llm_grunt
        nuance = @context.llm_nuance
        return { "shared" => grunt } if grunt.equal?(nuance) || nuance.nil?
        out = {}
        out["grunt"]  = grunt if grunt
        out["nuance"] = nuance if nuance
        out
      end

      def call_models(user)
        ::Harness::CostTracker.in_subsystem(:shadow_planner) do
          adapters_by_tier.transform_values { |adapter| call_one(adapter, user) }
        end
      end

      def call_one(adapter, user)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raw = adapter.complete(system: preamble, user: user)
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        parsed = parse_plan(raw)
        {
          "model"       => safe_model_name(adapter),
          "duration_ms" => elapsed_ms,
          "raw"         => raw.to_s[0, 4000],
          "plan"        => parsed[:plan],
          "parse_error" => parsed[:error]
        }
      rescue StandardError => e
        @logger.warn { "[Shadow::Planner] call failed: #{e.class}: #{e.message}" }
        {
          "model"       => safe_model_name(adapter),
          "duration_ms" => nil,
          "raw"         => nil,
          "plan"        => nil,
          "parse_error" => "#{e.class}: #{e.message}"
        }
      end

      # Parse the model output into a normalized plan array, or capture why we
      # couldn't. Tolerant of code fences (JsonResponse) and of stray prose
      # around the object (first balanced {...} fallback).
      def parse_plan(raw)
        obj = begin
          ::Harness::LLM::JsonResponse.parse(raw)
        rescue StandardError
          fallback_extract(raw)
        end
        return { plan: nil, error: "no JSON object found" } unless obj.is_a?(Hash)

        steps = obj["plan"]
        return { plan: nil, error: "missing 'plan' array" } unless steps.is_a?(Array)

        normalized = steps.map { |s| normalize_step(s) }
        { plan: normalized, error: nil }
      end

      def normalize_step(step)
        return { "runner" => nil, "reason" => nil, "args" => {}, "invalid" => "step not an object" } unless step.is_a?(Hash)
        runner = step["runner"].to_s
        entry = {
          "runner" => runner,
          "reason" => step["reason"].to_s[0, 300],
          "args"   => step["args"].is_a?(Hash) ? step["args"] : {}
        }
        entry["invalid"] = "unknown runner #{runner.inspect}" unless VALID_RUNNERS.include?(runner)
        entry
      end

      def fallback_extract(raw)
        text = raw.to_s
        start = text.index("{")
        finish = text.rindex("}")
        return nil unless start && finish && finish > start
        JSON.parse(text[start..finish])
      rescue StandardError
        nil
      end

      def user_message(world)
        payload = {
          "player_input"       => @input,
          "present_characters" => world["present_characters"] || [],
          "present_items"      => world["present_items"] || [],
          "nearby_locations"   => world["nearby_locations"] || [],
          "recent_history"     => world["recent_history"] || []
        }
        "INPUT:\n#{JSON.pretty_generate(payload)}"
      end

      # Compact, planner-only world view. Deliberately NOT QueryScene.build —
      # the planner doesn't need lens / internal_state / agenda / abilities.
      # Just who/what/where, enough to tell movement from worldbuilding and
      # to bind names to ids.
      def world_view
        loc = @context.player_location
        active = @scene_manager.active

        present_characters = []
        present_items = []
        if active && active.location.id == loc.id
          present_characters = active.present_characters.map { |c|
            { "id" => c.id, "name" => c.name, "subrole" => c.subrole }
          }
          present_items = active.present_items.map { |i| { "id" => i.id, "name" => i.name } }
        else
          # Fall back to a direct assembly if no matching active scene (rare:
          # mid-transition). Keeps the planner's view honest.
          snap = ::Harness::Scene::Assembler.for(location: loc)
          present_characters = snap.present_characters.map { |c|
            { "id" => c.id, "name" => c.name, "subrole" => c.subrole }
          }
          present_items = snap.present_items.map { |i| { "id" => i.id, "name" => i.name } }
        end

        {
          "present_characters" => present_characters,
          "present_items"      => present_items,
          "nearby_locations"   => nearby_locations(loc),
          "recent_history"     => recent_history
        }
      end

      def nearby_locations(loc)
        out = []
        out << { "id" => loc.parent.id, "name" => loc.parent.name, "rel" => "parent" } if loc.parent
        if loc.parent_id
          ::Location.where(parent_id: loc.parent_id).where.not(id: loc.id).each do |s|
            out << { "id" => s.id, "name" => s.name, "rel" => "sibling" }
          end
        end
        ::Location.where(parent_id: loc.id).each do |c|
          out << { "id" => c.id, "name" => c.name, "rel" => "child" }
        end
        out
      end

      def recent_history
        (@scene_manager.active&.narrations || []).last(RECENT_HISTORY_CAP)
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end

      def safe_model_name(adapter)
        adapter.respond_to?(:display_model) ? adapter.display_model : adapter.class.name
      rescue StandardError
        adapter.class.name
      end
    end
  end
end
