module Harness
  module Runners
    # The player goes somewhere that already exists. Resolves the destination
    # against the LIVE scene (per locked decision #1 — never trust a plan-time
    # id) and executes transition (intra-city) or travel (inter-city).
    #
    # One structured LLM call to pick the destination from real candidates;
    # the rest is deterministic tool execution. If the place doesn't exist yet
    # it returns :redispatch — the chain needs a worldbuilding step first
    # (that runner lands later; until then the executor logs `unresolved:`).
    class Movement < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/movement.txt")

      def run(context:, scene:, input:, step:)
        # Create-then-enter handoff: when an earlier worldbuilding step in this
        # chain created the destination, the executor hands us its row directly
        # (the player asked for "a forest"; the place got named "The Blackwood",
        # so re-searching the player's word would never find it). Go straight
        # there — sublocation → transition, wilderness_leaf → travel — and skip
        # the LLM decision entirely.
        if (dest = step&.args&.dig("_resolved_destination")).is_a?(Hash) && dest["id"]
          return enter_resolved(context, dest)
        end

        nearby = movement_targets(scene)
        decision = decide(context, input, step, nearby)
        resolver = resolver_for(context)
        tcs = []

        # Only a genuine LLM/parse failure re-dispatches. A clean decision —
        # including "none" — is handled in-runner. Edge cases live HERE, not
        # in the planner.
        return redispatch("movement decision unavailable") if decision.nil?

        case decision["action"]
        when "transition"
          tid = decision["target_id"]
          return redispatch("transition target not resolved", tcs) unless tid
          dest_name = nearby.find { |n| n["id"] == tid }&.dig("name") || "there"
          return declined(dest_name) unless confirm_scene_change(context, dest_name)
          _, ok = execute_tool(resolver, "transition", { "destination_id" => tid }, into: tcs)
          return redispatch("transition failed for id=#{tid}", tcs) unless ok
          Outcome.new(tool_calls: tcs, scene_dirty: true, status: :ok)

        when "travel"
          name = decision["place_name"].to_s
          return redispatch("no place name for travel", tcs) if name.empty?
          return declined(name) unless confirm_scene_change(context, name)
          res, ok = execute_tool(resolver, "query_location_by_name", { "name" => name }, into: tcs)
          if ok && res.is_a?(Hash) && res["found"] && res["location_id"]
            _, tok = execute_tool(resolver, "travel", { "destination_id" => res["location_id"] }, into: tcs)
            return redispatch("travel failed for '#{name}'", tcs) unless tok
            Outcome.new(tool_calls: tcs, scene_dirty: true, status: :ok)
          else
            # A named place that doesn't exist yet → a real move that needs the
            # place created first. Re-dispatch (→ worldbuilding, once built).
            redispatch("destination '#{name}' not found", tcs)
          end

        else
          # "none" — NOT a concrete location change: the player is approaching
          # someone already present ("walk up to Marnie"), turning, gesturing,
          # or being vague. We don't model intra-scene position outside combat,
          # so there's nothing mechanical to do — positioning is narration
          # flavor. EARLY-EXIT as a no-op so the chain continues to the next
          # step (usually conversation). No re-dispatch, no re-plan round-trip.
          # This is why the planner doesn't need an "approach-a-person is
          # conversation" rule — the runner recognizes it and yields cheaply.
          @logger.debug { "[Runner movement] no concrete destination → yield (narration flavor)" }
          Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok, note: "no concrete destination; positioning is narration")
        end
      end

      private

      # Mechanical confirmation before an irreversible scene change: the planner
      # (a weak model) can mis-read a mid-conversation question as a movement
      # command and teleport the player out of the room. Rather than keep
      # hardening the planner's judgment, gate the actual exit — ask the player.
      # No confirmer wired (headless / tests) → auto-confirm, never block.
      # Chain-created create-then-enter (enter_resolved) is NOT gated: that path
      # only runs on an explicit "make X and go there", where intent is certain.
      def confirm_scene_change(context, dest_name)
        confirmer = context.confirm_scene_change
        confirmer.nil? || confirmer.call(dest_name)
      end

      # Player declined the move at the gate. Halt the turn: no transition
      # commits, the executor aborts the chain, and the loop shows an OOC notice
      # and records nothing — the turn leaves no trace (reset to before it).
      def declined(dest_name)
        @logger.info { "[Runner movement] player declined scene change → #{dest_name.inspect}; halting turn" }
        Outcome.new(tool_calls: [], scene_dirty: false, status: :halted,
                    note: "that read as leaving for #{dest_name}, and I wasn't sure you meant to")
      end

      # Enter a location the chain just created. wilderness_leaf is a top-level
      # coordinated place → travel; anything else (sublocation child) → transition.
      def enter_resolved(context, dest)
        resolver = resolver_for(context)
        tcs = []
        tool = dest["type"].to_s == "wilderness_leaf" ? "travel" : "transition"
        _, ok = execute_tool(resolver, tool, { "destination_id" => dest["id"] }, into: tcs)
        return redispatch("#{tool} failed for chain-created location id=#{dest['id']}", tcs) unless ok
        @logger.debug { "[Runner movement] entered chain-created #{dest['name'].inspect} via #{tool}" }
        Outcome.new(tool_calls: tcs, scene_dirty: true, status: :ok, note: "entered #{dest['name']}")
      end

      def movement_targets(scene)
        out = []
        if (p = scene["parent"])
          out << { "id" => p["id"], "name" => p["name"], "rel" => "parent" }
        end
        Array(scene["siblings"]).each { |s| out << { "id" => s["id"], "name" => s["name"], "rel" => "sibling" } }
        Array(scene["children"]).each { |c| out << { "id" => c["id"], "name" => c["name"], "rel" => "child" } }
        out
      end

      def decide(context, input, step, nearby)
        user = JSON.pretty_generate(
          "player_input" => input,
          "intent"       => step&.intent,
          "nearby"       => nearby
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_movement) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)   # nil on parse failure → run() re-dispatches
      rescue StandardError => e
        @logger.warn { "[Runner movement] decide failed: #{e.class}: #{e.message}" }
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
