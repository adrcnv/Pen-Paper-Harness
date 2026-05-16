module Harness
  module LLM
    # Scripted stand-in for tests and smoke runs.
    #
    # reasoning: pass an array of {tool:, args:} hashes; FakeTurn hands them
    # out one at a time as next_tool_call, accepts feed_result, completes
    # when the script is drained. Results fed in are captured on the turn
    # object.
    #
    # narration: pass a string, or a proc that takes the user prompt and
    # returns a string (useful for "narrate based on the outcome" smoke
    # tests).
    class FakeAdapter < Adapter
      attr_reader :last_turn, :reasoning_calls, :narration_calls

      def initialize(reasoning: [], narration: "(no narration)")
        @reasoning_script = reasoning
        @narration        = narration
        @reasoning_calls  = []
        @narration_calls  = []
      end

      def start_turn(system:, user:, tools:)
        @reasoning_calls << { system: system, user: user, tools: tools }
        @last_turn = FakeTurn.new(@reasoning_script)
      end

      def complete(system:, user:)
        @narration_calls << { system: system, user: user }
        @narration.respond_to?(:call) ? @narration.call(user) : @narration
      end
    end
  end
end
