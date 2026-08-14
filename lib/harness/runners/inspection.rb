module Harness
  module Runners
    # The player looked / examined / asked "what's here" — pure observation,
    # no state change. ZERO LLM calls in the runner itself.
    #
    # We build the scene snapshot in Ruby (QueryScene.build — plain SQL) and
    # ship it as a query_scene tool_call result; Turn::Parts renders it as
    # the dry mechanical scene card, and the perception pass paints what the
    # player sees on top. This is the cheapest possible turn and the
    # canonical proof that the dispatcher→runner seam works end-to-end.
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
