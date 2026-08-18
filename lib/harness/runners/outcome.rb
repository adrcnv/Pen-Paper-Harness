module Harness
  module Runners
    # What a runner hands back to the executor. tool_calls is the
    # [{name:, args:, result:}, ...] shape Turn::Parts renders from.
    #
    # status:
    #   :ok         — step done; continue the chain.
    #   :redispatch — the runner could not bind its intent to live world
    #                 state (e.g. the NPC it expected isn't here). The
    #                 executor re-plans the remaining work, bounded by
    #                 REDISPATCH_CAP. NOT a soft fallback — a signal that the
    #                 plan went stale under the world.
    #   :skipped    — the step's referent deterministically does not exist
    #                 (an item only ever mentioned in fiction, a recipient
    #                 that isn't a row). Re-planning can never fix it, so the
    #                 executor marks THIS step unresolved and CONTINUES the
    #                 chain — one dead step must not kill the independent
    #                 steps behind it (the stuck-tankard turn: a phantom-ale
    #                 pickup hard-stopped the walk AND the question).
    #   :combat     — the step entered combat. Hard terminator: the executor
    #                 aborts remaining steps and the turn loop's combat
    #                 hand-off takes over.
    #   :halted     — the player declined an irreversible action at a mechanical
    #                 confirmation gate (e.g. a scene-change they didn't mean).
    #                 Hard terminator: the executor aborts remaining steps, and
    #                 the turn loop narrates/records NOTHING and shows `note` as
    #                 an OOC notice — the turn leaves no trace (reset to before).
    Outcome = Struct.new(:tool_calls, :scene_dirty, :status, :note, keyword_init: true) do
      def initialize(tool_calls: [], scene_dirty: false, status: :ok, note: nil)
        super
      end

      def ok?         = status == :ok
      def redispatch? = status == :redispatch
      def skipped?    = status == :skipped
      def combat?     = status == :combat
      def halted?     = status == :halted
    end
  end
end
