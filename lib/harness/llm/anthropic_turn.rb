module Harness
  module LLM
    # Wraps the agentic reasoning-loop conversation with Anthropic.
    #
    # Responsibilities:
    #   - Keep the running `messages` array across multiple API roundtrips.
    #   - Parse tool_use blocks out of the assistant's response, queue them.
    #   - Expose one tool call at a time via next_tool_call (FakeTurn parity).
    #   - Collect tool_results and send them back in a single user message
    #     once the current batch is drained.
    #   - Stop when the model returns stop_reason != "tool_use".
    #
    # The Anthropic API may emit multiple tool_use blocks in one response.
    # The resolver doesn't care — it runs one at a time — but we must reply
    # to ALL of them in one user message before making the next API call,
    # or the API will reject the conversation as malformed.
    class AnthropicTurn
      attr_reader :logger, :messages

      def initialize(adapter:, system:, user:, tools:, logger:)
        @adapter             = adapter
        @system              = system
        @tools               = tools
        @logger              = logger
        @messages            = [ { "role" => "user", "content" => user } ]
        @pending_tool_uses   = []   # queue of tool_use blocks from last response
        @pending_results     = []   # tool_result blocks accumulated for next batch
        @current_tool_use    = nil
        @done                = false
        @assistant_texts     = []   # text blocks the model emitted, in order

        fetch_next
      end

      def next_tool_call
        return nil if complete?
        return nil if @pending_tool_uses.empty?

        @current_tool_use = @pending_tool_uses.first
        ToolCall.new(
          name: @current_tool_use["name"],
          args: @current_tool_use["input"] || {}
        )
      end

      def feed_result(result)
        raise "feed_result called without a pending tool_use" if @current_tool_use.nil?

        @pending_results << {
          "type"        => "tool_result",
          "tool_use_id" => @current_tool_use["id"],
          "content"     => result_to_content(result)
        }
        @pending_tool_uses.shift
        @current_tool_use = nil

        flush_results_and_continue if @pending_tool_uses.empty? && !@done
      end

      def complete?
        @done && @pending_tool_uses.empty? && @current_tool_use.nil?
      end

      # Text blocks the model emitted across the reasoning loop, in order.
      # Useful for transcript logging. Not consumed by the narration step.
      def final_text
        @assistant_texts.join("\n")
      end

      private

      def fetch_next
        response = @adapter.post_messages(
          system:   @system,
          messages: @messages,
          tools:    @tools
        )

        content = Array(response["content"])
        @messages << { "role" => "assistant", "content" => content }

        content.each do |block|
          case block["type"]
          when "text"
            @assistant_texts << block["text"]
          when "tool_use"
            @pending_tool_uses << block
          end
        end

        if response["stop_reason"] == "tool_use"
          # model wants tool results — keep the turn open
        else
          @done = true
          logger.info { "[AnthropicTurn] done: stop_reason=#{response["stop_reason"].inspect} text_blocks=#{@assistant_texts.size}" }
        end
      end

      def flush_results_and_continue
        @messages << { "role" => "user", "content" => @pending_results }
        @pending_results = []
        fetch_next
      end

      def result_to_content(result)
        case result
        when String then result
        else             JSON.generate(result)
        end
      end
    end
  end
end
