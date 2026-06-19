module Harness
  module Turn
    # Captures everything that happened in a single turn for persistence.
    # The loop writes this to the turn_logs table at end of turn. Scrubbing
    # a bad turn later = loading this row, reading tool_calls in order.
    class Transcript
      attr_accessor :input, :reasoning_prompt, :narration, :narration_prompt,
                    :location_id, :error, :combat, :unresolved, :notice
      attr_reader :tool_calls

      def initialize(input:, location_id: nil)
        @input            = input
        @location_id      = location_id
        @tool_calls       = []
        @reasoning_prompt = nil
        @narration_prompt = nil
        @narration        = nil
        @error            = nil
        @combat           = nil
        # When a chain dead-ends (redispatch cap, unbuilt runner, failed
        # re-plan), this holds the intent that could not be carried out. It's
        # the signal to narration that the player's action did NOT happen — so
        # it renders a non-event instead of fabricating success.
        @unresolved       = nil
        # Out-of-character line shown to the PLAYER (not the fiction, not
        # recorded into scene history) when a turn dead-ends — a justified
        # wall-break so they know it was an engine limit, not an in-world
        # refusal, and can rephrase. The frontend prints it after narration.
        @notice           = nil
      end

      def record_tool_call(call, result)
        @tool_calls << {
          "name"   => call.name,
          "args"   => call.args,
          "result" => result
        }
      end

      # Append pre-built tool_call records ({name:, args:, result:} hashes) —
      # the shape runners return in their Outcome. Used by the state-machine
      # executor; the agentic loop uses record_tool_call (ToolCall + result).
      def record_tool_calls(calls)
        @tool_calls.concat(Array(calls))
      end

      # Returns the persisted TurnLog row.
      def persist!
        @turn_log ||= ::TurnLog.create!(
          turn_number:          ::TurnLog.next_turn_number,
          location_id:          @location_id,
          input:                @input,
          reasoning_prompt:     @reasoning_prompt,
          reasoning_tool_calls: @tool_calls,
          narration_prompt:     @narration_prompt,
          narration:            @narration,
          error:                @error
        )
      end

      def turn_log
        @turn_log
      end
    end
  end
end
