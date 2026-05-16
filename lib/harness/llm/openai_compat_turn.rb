module Harness
  module LLM
    # Wraps the agentic reasoning-loop conversation with an OpenAI-compatible
    # server. Mirrors AnthropicTurn's contract (next_tool_call / feed_result /
    # complete? / final_text) but in OpenAI Chat Completions shape.
    #
    # Shape differences worth knowing:
    #   - Assistant tool calls come in `message.tool_calls[]` alongside
    #     `message.content` (which may be empty when the model only called
    #     tools). We append the entire assistant message back to the running
    #     `messages` array so the server has the call context for the next
    #     round.
    #   - Tool results are their own messages with `role: "tool"` and a
    #     `tool_call_id` pointing at the originating call. One message per
    #     result, not bundled like Anthropic's user-content-blocks pattern.
    #   - The loop continues while `finish_reason == "tool_calls"`.
    #
    # Reasoning trace: Qwen 3.6 and similar models emit chain-of-thought into
    # `message.reasoning_content`. We capture it on @assistant_thoughts for
    # transcript logging but it's not fed back into the conversation — only
    # the visible content + tool_calls round-trip.
    class OpenAICompatTurn
      attr_reader :logger, :messages

      def initialize(adapter:, system:, user:, tools:, enable_thinking:, logger:)
        @adapter             = adapter
        @tools               = tools
        @enable_thinking     = enable_thinking
        @logger              = logger
        @messages            = []
        @messages << { "role" => "system", "content" => system } if system.is_a?(String) && !system.empty?
        @messages << { "role" => "user",   "content" => user }

        @pending_tool_calls  = []  # queue of tool_call dicts from last response
        @current_tool_call   = nil
        @done                = false
        @assistant_texts     = []
        @assistant_thoughts  = []

        fetch_next
      end

      def next_tool_call
        return nil if complete?
        return nil if @pending_tool_calls.empty?

        @current_tool_call = @pending_tool_calls.first
        ToolCall.new(
          name: @current_tool_call.dig("function", "name"),
          args: parse_args(@current_tool_call.dig("function", "arguments"))
        )
      end

      def feed_result(result)
        raise "feed_result called without a pending tool_call" if @current_tool_call.nil?

        @messages << {
          "role"         => "tool",
          "tool_call_id" => @current_tool_call["id"],
          "content"      => result_to_content(result)
        }
        @pending_tool_calls.shift
        @current_tool_call = nil

        fetch_next if @pending_tool_calls.empty? && !@done
      end

      def complete?
        @done && @pending_tool_calls.empty? && @current_tool_call.nil?
      end

      def final_text
        @assistant_texts.join("\n")
      end

      # Reasoning trace, if the model emitted any. Useful for transcript
      # debugging; not consumed by the narration step.
      def final_thoughts
        @assistant_thoughts.join("\n")
      end

      private

      def fetch_next
        response = @adapter.post_chat(
          messages:        @messages,
          tools:           @tools,
          enable_thinking: @enable_thinking
        )

        choice  = response.dig("choices", 0) || {}
        message = choice["message"] || {}
        finish  = choice["finish_reason"]

        # Echo the full assistant message back so the server sees its own
        # tool_calls on the next round-trip. content may be nil when the
        # model only emitted tool_calls — normalize to "" so the server
        # doesn't reject the message shape.
        echo = { "role" => "assistant", "content" => message["content"].to_s }
        echo["tool_calls"] = message["tool_calls"] if message["tool_calls"].is_a?(Array) && !message["tool_calls"].empty?
        @messages << echo

        text = message["content"]
        @assistant_texts << text if text.is_a?(String) && !text.empty?

        thoughts = message["reasoning_content"]
        @assistant_thoughts << thoughts if thoughts.is_a?(String) && !thoughts.empty?

        Array(message["tool_calls"]).each do |tc|
          @pending_tool_calls << tc if tc.is_a?(Hash) && tc["id"]
        end

        if finish == "tool_calls" && !@pending_tool_calls.empty?
          # model wants tool results — keep the turn open
        else
          @done = true
          logger.info { "[OpenAICompatTurn] done: finish_reason=#{finish.inspect} text_blocks=#{@assistant_texts.size}" }
        end
      end

      def parse_args(raw)
        return {} if raw.nil? || raw == ""
        return raw if raw.is_a?(Hash)
        JSON.parse(raw)
      rescue JSON::ParserError
        logger.warn { "[OpenAICompatTurn] tool args not valid JSON, passing empty hash: #{raw.to_s.slice(0, 200)}" }
        {}
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
