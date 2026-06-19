module Harness
  module Runners
    # The player expects something that doesn't exist yet (a tavern, a smith,
    # a market). One structured call describes the minimal creation; Ruby runs
    # the CREATE chain (location → character → item → kickoff) via tools. This
    # replaces the agentic loop's multi-call worldbuilding spray with a bounded
    # commit.
    #
    # Kickoff is committed FORWARD (now), not backward: a just-spawned
    # character has no earlier floor, so a backward origin event would trip the
    # floor-violation guard (observed in the agentic fallback). Backward origin
    # is a later refinement.
    class Worldbuilding < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/worldbuilding.txt")

      def run(context:, scene:, input:, step:)
        spec = author(context, input, step, scene)
        return redispatch("worldbuilding emit unparseable") if spec.nil?

        # All-null = DEFLECT (the world doesn't contain this). Nothing to build;
        # narration renders the non-answer. Not a failure → :ok no-op.
        if %w[location character item kickoff].all? { |k| spec[k].nil? }
          @logger.debug { "[Runner worldbuilding] all-null spec → deflect (no-op)" }
          return Outcome.new(tool_calls: [], scene_dirty: false, status: :ok, note: "deflected; nothing to create")
        end

        resolver = resolver_for(context)
        tcs = []
        city_id = nearest_city_id(context)
        new_loc_id = nil
        new_char_id = nil

        if (loc = spec["location"]).is_a?(Hash)
          args = {
            "name"        => loc["name"].to_s.presence || "New Place",
            "description" => loc["description"].to_s,
            "type"        => %w[sublocation wilderness_leaf].include?(loc["type"]) ? loc["type"] : "sublocation",
            "connection"  => loc["connection"].to_s.presence || "implied by the surrounding area"
          }
          args["parent_id"] = city_id if args["type"] == "sublocation"
          res, ok = execute_tool(resolver, "propose_location", args, into: tcs)
          new_loc_id = res["location_id"] || res["id"] if ok && res.is_a?(Hash)
        end

        if (ch = spec["character"]).is_a?(Hash)
          args = {
            "name"        => ch["name"].to_s.presence || "Stranger",
            "subrole"     => ch["subrole"].to_s.presence || "commoner",
            "connection"  => ch["connection"].to_s.presence || "tied to this place",
            "location_id" => new_loc_id || city_id
          }
          args["properties"] = { "physical" => ch["description"] } if ch["description"].to_s.strip != ""
          res, ok = execute_tool(resolver, "propose_character", args, into: tcs)
          new_char_id = res["character_id"] || res["id"] if ok && res.is_a?(Hash)
        end

        if (it = spec["item"]).is_a?(Hash)
          execute_tool(resolver, "propose_item", {
            "name"        => it["name"].to_s.presence || "an object",
            "subrole"     => it["subrole"].to_s.presence || "object",
            "connection"  => it["connection"].to_s.presence || "found here",
            "location_id" => new_loc_id || city_id
          }, into: tcs)
        end

        if (kp = spec["kickoff"]).is_a?(Hash) && kp["details"].to_s.strip != "" && new_char_id
          execute_tool(resolver, "propose_event", {
            "scope"        => %w[personal local regional kingdom world].include?(kp["scope"]) ? kp["scope"] : "local",
            "participants" => [ { "character_id" => new_char_id, "role" => "actor" } ],
            "trigger"      => "establishment",
            "details"      => kp["details"],
            "location_id"  => new_loc_id || city_id,
            "time_minutes" => 1
          }, into: tcs)
        end

        return redispatch("worldbuilding produced no commits", tcs) if tcs.all? { |t| t.dig("result", "error") }
        Outcome.new(tool_calls: tcs, scene_dirty: new_loc_id ? false : false, status: :ok)
      end

      private

      def nearest_city_id(context)
        loc = context.player_location
        loc.parent_id || loc.id
      end

      def author(context, input, step, scene)
        here = scene && scene["location"]
        user = JSON.pretty_generate(
          "player_input" => input,
          "intent"       => step&.intent,
          "here"         => here,
          "nearby"       => Array(scene && scene["children"])
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_worldbuilding) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner worldbuilding] author failed: #{e.class}: #{e.message}" }
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
