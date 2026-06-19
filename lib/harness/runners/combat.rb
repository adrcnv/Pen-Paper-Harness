module Harness
  module Runners
    # Combat ENTRY. The fight itself is Combat::Loop (already a state machine);
    # this runner only sets up the sides and calls start_combat, then returns
    # :combat — a hard terminator. The executor aborts the rest of the chain
    # and Turn::Loop's existing combat hand-off runs Combat::Loop.
    #
    # start_combat does the heavy lifting (validates sides, auto-includes
    # followers, runs bystander deliberation, rolls initiative, switches the
    # tool surface). We just hand it well-formed sides.
    class Combat < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/combat.txt")

      def run(context:, scene:, input:, step:)
        player = ::Player.first
        return redispatch("no player row") unless player

        spec = decide(context, input, step, scene, player)
        return redispatch("combat emit unparseable") if spec.nil?

        enemies = Array(spec["enemy_side"]).compact.uniq
        return redispatch("no opponent present for combat") if enemies.empty?

        allies = Array(spec["player_side"]).compact.uniq
        allies << player.id unless allies.include?(player.id)
        allies -= enemies # safety: a member can't be on both sides

        resolver = resolver_for(context)
        tcs = []
        _, ok = execute_tool(resolver, "start_combat", {
          "sides" => [
            { "name" => "player_party", "members" => allies },
            { "name" => "hostiles",     "members" => enemies }
          ],
          "inciting_beat" => spec["inciting_beat"].to_s.presence || "violence breaks out"
        }, into: tcs)

        return redispatch("start_combat rejected", tcs) unless ok

        # Hard terminator: stop the chain; Turn::Loop sees scene.in_combat? and
        # runs the round driver.
        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :combat)
      end

      private

      def decide(context, input, step, scene, player)
        present = Array(scene && scene["present_characters"]).map { |c|
          { "id" => c["id"], "name" => c["name"], "subrole" => c["subrole"],
            "following_player" => c["following_player"] == true }
        }
        user = JSON.pretty_generate(
          "player_input"       => input,
          "intent"             => step&.intent,
          "player"             => { "id" => player.id, "name" => player.name },
          "present_characters" => present
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_combat) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner combat] decide failed: #{e.class}: #{e.message}" }
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
