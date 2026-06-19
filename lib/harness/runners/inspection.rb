module Harness
  module Runners
    # The player looked / examined / asked "what's here" — pure observation,
    # no state change. ZERO LLM calls.
    #
    # We build the scene snapshot in Ruby (QueryScene.build — plain SQL) and
    # hand it to narration as a query_scene tool_call result. Narration then
    # renders the room from real structured input, exactly as if the agentic
    # loop had opened with query_scene — but without the round-trip or any
    # write. This is the cheapest possible turn and the canonical proof that
    # the dispatcher→runner→narration seam works end-to-end.
    class Inspection < Base
      def run(context:, scene:, input:, step:)
        snapshot = scene || ::Harness::Tools::QueryScene.build(context)
        @logger.debug { "[Runner inspection] 0-LLM; rendering scene at #{context.player_location&.name} (#{snapshot['present_characters']&.size || 0} present)" }
        Outcome.new(
          tool_calls: [ tool_call("query_scene", {}, snapshot) ],
          scene_dirty: false,
          status: :ok
        )
      end
    end
  end
end
