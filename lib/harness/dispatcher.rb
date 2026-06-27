module Harness
  # Live dispatcher: classifies the player input into an ordered PLAN of
  # runner steps, and owns the runner registry. This is the shadow planner
  # promoted to drive execution instead of just logging.
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

    def plan(input)
      res = ::Harness::CostTracker.in_subsystem(:dispatcher) do
        ::Harness::Shadow::Planner.plan_for(
          context: @context, scene_manager: @scene_manager, input: input, logger: @logger
        )
      end

      steps = Array(res["plan"]).map { |s|
        Step.new(runner: normalize_runner(s["runner"]), intent: s["reason"], args: s["args"] || {})
      }
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

    # The standalone "dice" runner was retired — a roll belongs INSIDE an
    # interaction, not as its own step (movement-as-a-dice-step was the bug that
    # started this). The planner prompt no longer offers "dice", but a weak local
    # model may still emit it from habit; remap it to environment (the home for
    # bare physical/athletic attempts: climb, swim, force) so the turn doesn't
    # needlessly fall back to agentic on an unbuilt label.
    RETIRED_RUNNER_REMAP = { "dice" => "environment" }.freeze
    def normalize_runner(label)
      mapped = RETIRED_RUNNER_REMAP[label.to_s]
      return label unless mapped
      @logger.info { "[Dispatcher] remapped retired runner 'dice' → '#{mapped}'" }
      mapped
    end

    # A runner is "built" if the registry has a real implementation for it.
    # Unbuilt labels (movement/conversation/... before they land) signal the
    # executor to run the whole turn agentically — a BUILD-TIME scaffold, not
    # a per-step fallback. Shrinks to nothing as runners are added.
    def built?(label)
      @registry.key?(label.to_s)
    end

    def runner_for(label)
      @registry[label.to_s]
    end

    def runner_labels = @registry.keys
  end
end
