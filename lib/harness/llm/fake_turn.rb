module Harness
  module LLM
    class FakeTurn
      attr_reader :results

      def initialize(script)
        @script  = script.dup
        @results = []
        @current = nil
      end

      def next_tool_call
        return nil if @script.empty?
        @current = @script.first
        ToolCall.new(name: @current[:tool], args: @current[:args] || {})
      end

      def feed_result(result)
        entry = @script.shift
        @results << { call: entry, result: result }
        @current = nil
      end

      def complete?
        @script.empty? && @current.nil?
      end
    end
  end
end
