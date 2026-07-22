require "json"

module Harness
  # THE planner. Builds a tight planning prompt from a compact world view,
  # calls the session model once, and parses the result into a normalized plan
  # (an ordered list of runner steps + the model's reasoning). Executes nothing
  # and mutates nothing — the Dispatcher turns this into Step structs and the
  # executor runs them.
  #
  # (Formerly Shadow::Planner — a diagnostic that shadowed the agentic loop to
  # validate the state-machine rework. That theory is validated and shipped;
  # the shadow/two-tier/offline-replay scaffolding is gone. This is the live
  # planner it became.)
  class Planner
    PROMPT_PATH = Rails.root.join("lib/harness/prompts/planner.txt")
    RECENT_HISTORY_CAP = 4

    VALID_RUNNERS = %w[
      inspection movement conversation worldbuilding
      inventory dice time-skip combat meta agentic
    ].freeze

    # The dispatcher's single-plan entry. ONE model call (the session model via
    # llm_nuance, falling back to llm_grunt). Returns:
    #   { "model","duration_ms","raw","reasoning","plan","parse_error","world" }
    def self.plan_for(context:, scene_manager:, input:, logger: Rails.logger)
      new(input: input, logger: logger, context: context, scene_manager: scene_manager).plan_single
    end

    def initialize(input:, logger:, context:, scene_manager:)
      @input         = input
      @logger        = logger
      @context       = context
      @scene_manager = scene_manager
    end

    def plan_single
      world   = world_view
      adapter = @context.llm_nuance || @context.llm_grunt
      call_one(adapter, user_message(world)).merge("world" => world)
    end

    private

    def call_one(adapter, user)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw = adapter.complete(system: preamble, user: user)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      parsed = parse_plan(raw)
      {
        "model"       => safe_model_name(adapter),
        "duration_ms" => elapsed_ms,
        "raw"         => raw.to_s[0, 4000],
        "reasoning"   => parsed[:reasoning],
        "plan"        => parsed[:plan],
        "parse_error" => parsed[:error]
      }
    rescue StandardError => e
      @logger.warn { "[Planner] call failed: #{e.class}: #{e.message}" }
      {
        "model"       => safe_model_name(adapter),
        "duration_ms" => nil,
        "raw"         => nil,
        "plan"        => nil,
        "parse_error" => "#{e.class}: #{e.message}"
      }
    end

    # Parse the model output into a normalized plan array, or capture why we
    # couldn't. Tolerant of code fences (JsonResponse) and of stray prose around
    # the object (first balanced {...} fallback).
    def parse_plan(raw)
      obj = begin
        ::Harness::LLM::JsonResponse.parse(raw)
      rescue StandardError
        fallback_extract(raw)
      end
      return { plan: nil, reasoning: nil, error: "no JSON object found" } unless obj.is_a?(Hash)

      reasoning = obj["reasoning"].to_s.strip[0, 600].presence
      steps = obj["plan"]
      return { plan: nil, reasoning: reasoning, error: "missing 'plan' array" } unless steps.is_a?(Array)

      normalized = steps.map { |s| normalize_step(s) }
      normalized = collapse_consecutive(normalized, "conversation")
      { plan: normalized, reasoning: reasoning, error: nil }
    end

    # The conversation runner is ROOM-LEVEL: a single step voices EVERY present
    # character, each self-deciding whether it was addressed. So a turn that
    # addresses several present people — even with a separate quoted line to each
    # ("turn to Ingrid ... turn to Astrid ...") — is ONE conversation step, not
    # N. The weak planner keeps reading "two people addressed" as "two steps"
    # (the general compound-input rule), which re-voices the whole room once per
    # step (each NPC speaks twice). Collapse a run of consecutive `conversation`
    # steps into the first — mechanical guard, since prompt rules alone don't
    # hold the weak model here.
    def collapse_consecutive(steps, runner)
      steps.each_with_object([]) do |s, acc|
        prev = acc.last
        next if prev && prev["runner"] == runner && s["runner"] == runner
        acc << s
      end
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
        "player_input"        => @input,
        "present_characters"  => world["present_characters"] || [],
        "present_items"       => world["present_items"] || [],
        "nearby_locations"    => world["nearby_locations"] || [],
        "travel_destinations" => world["travel_destinations"] || [],
        "player_abilities"    => world["player_abilities"] || [],
        "recent_history"      => world["recent_history"] || []
      }
      "INPUT:\n#{JSON.pretty_generate(payload)}"
    end

    # Compact, planner-only world view. Deliberately NOT QueryScene.build — the
    # planner doesn't need lens / internal_state / agenda / abilities. Just
    # who/what/where, enough to tell movement from worldbuilding and to bind
    # names to ids.
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
        "present_characters"  => present_characters,
        "present_items"       => present_items,
        "nearby_locations"    => nearby_locations(loc),
        "travel_destinations" => travel_destinations(loc),
        "player_abilities"    => player_abilities,
        "recent_history"      => recent_history
      }
    end

    # Ability ids/names only — enough for the planner to bind a cast into a
    # step's check args ("cast charm word on her" → ability: charm_word).
    def player_abilities
      Array(::Player.first&.abilities).map { |a| { "id" => a["id"], "name" => a["name"] } }
    end

    # OTHER settlements on the world map — top-level, coordinate-anchored places
    # (what Tools::Travel accepts as a destination), minus wilderness leaves
    # (undiscovered lairs, not travel-listed) and the city the player is already
    # in. This is what makes inter-city travel routable: without it the planner
    # only ever sees adjacent places and mis-classifies every distant town as
    # "must be created" (→ worldbuilding → dedup-death). Kept small — worlds
    # carry a handful of cities.
    def travel_destinations(loc)
      here_root = loc
      here_root = here_root.parent while here_root.parent
      ::Location.where(parent_id: nil).where.not(x: nil, y: nil).where.not(id: here_root.id)
                .select(&:settlement?)
                .map { |l| { "id" => l.id, "name" => l.name } }
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
