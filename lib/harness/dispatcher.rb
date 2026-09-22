module Harness
  # Live dispatcher: classifies the player input into an ordered PLAN of
  # runner steps, and owns the runner registry. Wraps Harness::Planner (the
  # model call) and turns its result into Step structs for the executor.
  #
  # Returns Step structs. Per locked decision #1, a Step carries the runner
  # label + the planner's intent prose + arg HINTS only — never bound ids.
  # The runner resolves its own targets from live state when it executes.
  class Dispatcher
    Step = Struct.new(:runner, :intent, :args, keyword_init: true) do
      def to_s = "#{runner}(#{intent.to_s[0, 60]})"
    end

    # Result of a plan() call.
    #   steps:       [Step, ...]
    #   parse_error: String or nil (planner produced no usable plan)
    #   raw:         raw model output (for debugging a parse failure)
    #   ms:          planner latency
    #   model:       which model planned
    Plan = Struct.new(:steps, :reasoning, :parse_error, :raw, :ms, :model, keyword_init: true) do
      def empty?  = steps.nil? || steps.empty?
      def failed? = !parse_error.nil?
    end

    def initialize(context:, scene_manager:, registry:, logger: Rails.logger)
      @context       = context
      @scene_manager = scene_manager
      @registry      = registry
      @logger        = logger
    end

    # The player's own hands before the room answers: an inventory step the
    # router wrote right after a conversation step runs before it (adjacent
    # pairs only — a movement between them keeps its place). Run 7 t5: the
    # voice took coins the player did not have and a sale was struck on
    # credit, because the buy that would have said "you can't afford it"
    # ran second.
    def hands_first(steps)
      steps = steps.dup
      loop do
        i = (0...(steps.size - 1)).find { |k| steps[k].runner == "conversation" && steps[k + 1].runner == "inventory" }
        break unless i
        steps[i], steps[i + 1] = steps[i + 1], steps[i]
      end
      steps
    end

    # Whether the player's hands move on a talk turn is the inventory judge's
    # question, not the planner's: "Take it now, owe me two coins" was planned
    # as talk alone and the knife never left the player (hands run 9 t18).
    # The planner still orders the acts it names; where it named no hands
    # step beside a conversation, one runs before the room answers and says
    # nothing when the hands are still.
    def with_hands(steps)
      return steps if steps.none? { |s| s.runner == "conversation" } || steps.any? { |s| s.runner == "inventory" }
      i = steps.index { |s| s.runner == "conversation" }
      steps.dup.insert(i, Step.new(runner: "inventory", intent: nil, args: { "implicit" => true }))
    end

    def plan(input)
      res = ::Harness::CostTracker.in_subsystem(:dispatcher) do
        ::Harness::Planner.plan_for(
          context: @context, scene_manager: @scene_manager, input: input, logger: @logger
        )
      end

      steps = Array(res["plan"]).map { |s|
        # No label normalization: the grammar's enum can't emit unknown labels,
        # and anything else — the unconstrained-fallback path only — degrades
        # to inspection in the executor via built?.
        Step.new(runner: s["runner"], intent: s["reason"], args: s["args"] || {})
      }
      steps = with_hands(hands_first(steps))
      plan = Plan.new(
        steps:       steps,
        reasoning:   res["reasoning"],
        parse_error: res["parse_error"],
        raw:         res["raw"],
        ms:          res["duration_ms"],
        model:       res["model"]
      )

      if plan.failed?
        @logger.info  { "[Dispatcher] PARSE-FAIL (#{plan.ms}ms, #{plan.model}): #{plan.parse_error}" }
        @logger.debug { "[Dispatcher] raw output: #{plan.raw.to_s[0, 800]}" }
      else
        seq = steps.map(&:runner).join(" → ")
        @logger.info  { "[Dispatcher] plan (#{plan.ms}ms, #{plan.model}): [#{seq}]" }
        @logger.info  { "[Dispatcher] reasoning: #{plan.reasoning}" } if plan.reasoning.present?
        steps.each_with_index { |s, i| @logger.debug { "[Dispatcher]   step #{i + 1}: #{s.runner} — #{s.intent}" } }
        unbuilt = steps.map(&:runner).reject { |r| built?(r) }.uniq
        @logger.debug { "[Dispatcher] unbuilt runners in plan: #{unbuilt.inspect}" } if unbuilt.any?
      end
      plan
    end

    # A runner is "built" if the registry has a real implementation for it.
    # Unbuilt labels degrade to a safe inspection step in the executor.
    def built?(label)
      @registry.key?(label.to_s)
    end

    def runner_for(label)
      @registry[label.to_s]
    end

    def runner_labels = @registry.keys
  end
end
