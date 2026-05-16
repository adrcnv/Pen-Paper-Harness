module Harness
  module Turn
    # Captures everything that happened in a single turn for persistence.
    # The loop writes this to the turn_logs table at end of turn. Scrubbing
    # a bad turn later = loading this row, reading tool_calls in order.
    class Transcript
      attr_accessor :input, :reasoning_prompt, :narration, :narration_prompt,
                    :location_id, :error, :combat
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
      end

      def record_tool_call(call, result)
        @tool_calls << {
          "name"   => call.name,
          "args"   => call.args,
          "result" => result
        }
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
