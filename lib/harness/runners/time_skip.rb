module Harness
  module Runners
    # The player chooses to let time pass (rest / wait / sleep / linger). One
    # small structured call maps the phrase to {intent, duration_minutes};
    # Ruby calls pass_time (which advances the clock and may rebuild the scene
    # when it crosses the in-scene threshold).
    class TimeSkip < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/time_skip.txt")
      VALID_INTENTS = %w[rest wait sleep linger].freeze

      def run(context:, scene:, input:, step:)
        spec = decide(context, input, step)
        return redispatch("time-skip emit unparseable") if spec.nil?

        intent = VALID_INTENTS.include?(spec["intent"]) ? spec["intent"] : "wait"
        minutes = spec["duration_minutes"].to_i
        minutes = 60 if minutes <= 0

        resolver = resolver_for(context)
        tcs = []
        _, ok = execute_tool(resolver, "pass_time", { "intent" => intent, "duration_minutes" => minutes }, into: tcs)
        return redispatch("pass_time failed", tcs) unless ok

        Outcome.new(tool_calls: tcs, scene_dirty: context.scene_dirty, status: :ok)
      end

      private

      def decide(context, input, step)
        user = JSON.pretty_generate("player_input" => input, "intent" => step&.intent)
        raw = ::Harness::CostTracker.in_subsystem(:runner_time_skip) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner time_skip] decide failed: #{e.class}: #{e.message}" }
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
