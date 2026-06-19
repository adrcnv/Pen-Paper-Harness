module Harness
  module Runners
    # A mechanical action with real uncertainty. One structured call specifies
    # the roll (stat/ability, target, difficulty, time); Ruby calls resolve.
    # Optionally commits a single NPC reaction for a hostile beat (NON-COMBAT
    # CONFLICT) — a counter swing (resolve) or a flee/yield (propose_event).
    # A full multi-round fight is the combat runner's job, not this one.
    class Dice < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/dice.txt")
      MAX_PRESENT = 6

      def run(context:, scene:, input:, step:)
        player = ::Player.first
        return redispatch("no player row") unless player

        spec = decide(context, input, step, scene, player)
        return redispatch("dice emit unparseable") if spec.nil?
        return redispatch("dice emit lacks stat/ability") if spec["stat"].nil? && spec["ability_name"].nil?

        resolver = resolver_for(context)
        tcs = []
        promo = {} # extra_index → promoted character_id

        target_id = spec["target_id"]
        if target_id.nil? && spec["target_extra_index"].is_a?(Integer)
          target_id = promote_extra(resolver, context, scene, spec["target_extra_index"], spec["target_subrole"], into: tcs, cache: promo)
        end

        execute_tool(resolver, "resolve", {
          "actor_id"      => spec["actor_id"] || player.id,
          "stat"          => spec["stat"],
          "ability_name"  => spec["ability_name"],
          "action"        => spec["action"].to_s.presence || "an attempt",
          "target_id"     => target_id,
          "difficulty"    => spec["difficulty"],
          "roll_modifier" => spec["roll_modifier"],
          "time_minutes"  => spec["time_minutes"] || 2
        }, into: tcs)

        commit_npc_reaction(resolver, spec["npc_reaction"], player, tcs)

        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      private

      def commit_npc_reaction(resolver, rx, player, tcs)
        return unless rx.is_a?(Hash) && rx["actor_id"]
        case rx["kind"]
        when "counter"
          execute_tool(resolver, "resolve", {
            "actor_id"     => rx["actor_id"],
            "ability_name" => rx["ability_name"],
            "stat"         => rx["ability_name"] ? nil : "strength",
            "action"       => rx["prose"].to_s.presence || "strikes back",
            "target_id"    => player.id,
            "time_minutes" => 1
          }, into: tcs)
        else # flee / yield → a single narrative reaction event
          execute_tool(resolver, "propose_event", {
            "scope"        => "personal",
            "participants" => [ { "character_id" => rx["actor_id"], "role" => "actor" }, { "character_id" => player.id, "role" => "participant" } ],
            "trigger"      => rx["kind"].to_s.presence || "reaction",
            "details"      => rx["prose"].to_s.presence || "reacts to the player's action",
            "time_minutes" => 1
          }, into: tcs)
        end
      end

      def decide(context, input, step, scene, player)
        present = Array(scene && scene["present_characters"]).first(MAX_PRESENT).map { |c|
          { "id" => c["id"], "name" => c["name"], "subrole" => c["subrole"],
            "abilities" => Array(c["abilities"]).map { |a| a.is_a?(Hash) ? a["name"] : a } }
        }
        extras = Array(scene && scene["present_extras"]).each_with_index.map { |d, i| { "index" => i, "desc" => d } }
        user = JSON.pretty_generate(
          "player_input" => input,
          "intent"       => step&.intent,
          "player"       => { "id" => player.id, "name" => player.name },
          "present"      => present,
          "present_extras" => extras
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_dice) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner dice] decide failed: #{e.class}: #{e.message}" }
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
