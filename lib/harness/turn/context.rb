module Harness
  module Turn
    # Mutable per-turn (and cross-turn) state carried through the loop and
    # tools. Tools update player_location / scene_dirty; the loop reads them
    # at end of turn to decide whether to rebuild the scene.
    #
    # `history` is the running conversation log — appended after narration.
    # Hard-capped by the loop so the reasoning context doesn't balloon.
    #
    # Two LLM tiers thread through the context:
    #   llm_grunt   — small-model tier. Pattern-matching grunt work: stat /
    #                 ability materialization, internal-state prose,
    #                 contradiction validation, catch-up sim, genesis,
    #                 entity resolution. Per-turn hot path; latency and cost
    #                 matter.
    #   llm_nuance  — reasoning tier. Reasoning loop tool-use + narration
    #                 step. Larger model; once or twice per turn.
    #
    # Both are duck-typed adapters that respond to .call(prompt) for
    # synchronous one-shot calls. The reasoning loop and narration step use
    # the richer start_turn / complete interface on the adapter object
    # directly, not via context.
    #
    # `llm_client=` / `llm_client` are a back-compat shim from before the
    # split: setting llm_client wires both tiers to the same adapter, which
    # is the correct behavior for a single-adapter setup (one model doing
    # everything). New call sites should pick the tier explicitly.
    class Context
      attr_accessor :player_location, :scene_dirty, :game_time
      attr_accessor :llm_grunt, :llm_nuance
      attr_accessor :active_scene
      attr_reader   :history
      # Mechanical player confirmation for an irreversible scene change. A proc
      # `->(destination_name) { true|false }` set by the frontend (bin/play wires
      # a y/N prompt). nil = auto-confirm — headless runs and tests never block.
      # The movement runner calls this before it commits a transition/travel.
      attr_accessor :confirm_scene_change

      def initialize(player_location:, history: [], llm_client: nil, llm_grunt: nil, llm_nuance: nil, game_time: 0)
        @player_location = player_location
        @history         = history
        @game_time       = game_time
        @scene_dirty     = false

        # Explicit tier args win; llm_client fills any unset tier.
        @llm_grunt  = llm_grunt  || llm_client
        @llm_nuance = llm_nuance || llm_client
      end

      # Called at the start of each turn by Turn::Loop. Reserved for future
      # per-turn counter resets (none today; the belief-query spin-cap that
      # used this hook went away with the Belief layer).
      def reset_per_turn_counters!
        # no-op
      end

      # Back-compat shim: setting both tiers from a single client. Useful for
      # specs and single-adapter setups. Reading returns whichever tier is
      # set (grunt preferred since it's the per-turn hot path).
      def llm_client=(client)
        @llm_grunt  = client
        @llm_nuance = client
      end

      def llm_client
        @llm_grunt || @llm_nuance
      end

      def clear_scene_dirty!
        @scene_dirty = false
      end

      def append_turn(input:, narration:)
        @history << { "input" => input, "narration" => narration }
      end
    end
  end
end
