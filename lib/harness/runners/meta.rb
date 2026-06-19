module Harness
  module Runners
    # Out-of-character / meta / non-action input — a comment to the engine, a
    # joke, table-talk, a throwaway ("nice plot twist", "huh?", "lol"). NOT an
    # in-fiction action. ZERO LLM, ZERO state change.
    #
    # The point is to keep OOC text OUT of the conversation runner, where it
    # would be committed as the player addressing an NPC and the NPC would
    # answer the joke — an immersion break. Here we commit nothing and emit a
    # marker so narration knows not to advance the fiction or have anyone
    # react. (See the META rule in narration.txt.)
    class Meta < Base
      def run(context:, scene:, input:, step:)
        @logger.debug { "[Runner meta] OOC/non-action input → no-op (no one reacts, fiction holds)" }
        Outcome.new(
          tool_calls: [ tool_call("meta", { "input" => input.to_s[0, 200] }, { "out_of_character" => true }) ],
          scene_dirty: false,
          status: :ok,
          note: "out-of-character; fiction held"
        )
      end
    end
  end
end
