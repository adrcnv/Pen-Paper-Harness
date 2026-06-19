module Harness
  module Runners
    # What a runner hands back to the executor. Same tool_calls shape the
    # agentic loop produces ([{name:, args:, result:}, ...]) so narration
    # consumes it unchanged.
    #
    # status:
    #   :ok         — step done; continue the chain.
    #   :redispatch — the runner could not bind its intent to live world
    #                 state (e.g. the NPC it expected isn't here). The
    #                 executor re-plans the remaining work, bounded by
    #                 REDISPATCH_CAP. NOT a soft fallback — a signal that the
    #                 plan went stale under the world.
    #   :combat     — the step entered combat. Hard terminator: the executor
    #                 aborts remaining steps and the turn loop's combat
    #                 hand-off takes over.
    Outcome = Struct.new(:tool_calls, :scene_dirty, :status, :note, keyword_init: true) do
      def initialize(tool_calls: [], scene_dirty: false, status: :ok, note: nil)
        super
      end

      def ok?         = status == :ok
      def redispatch? = status == :redispatch
      def combat?     = status == :combat
    end
  end
end
