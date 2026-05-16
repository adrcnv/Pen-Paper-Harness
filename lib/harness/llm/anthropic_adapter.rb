require "net/http"
require "uri"
require "json"

module Harness
  module LLM
    # Anthropic Messages API adapter.
    #
    # The reasoning loop uses native tool_use blocks. The model emits one or
    # more tool_use content blocks per response; AnthropicTurn queues them
    # and hands them to the resolver one at a time via next_tool_call,
    # matching the shape FakeTurn established. feed_result collects
    # tool_result blocks and sends them back in a single user message once
    # the batch is drained.
    #
    # The narration step is a tool-less completion. Returns the concatenated
    # text blocks.
    #
    # Retries on 429 and 5xx with exponential backoff. Other errors raise.
    # HTTP is behind the http_client dep so specs can inject a stub without
    # WebMock.
    class AnthropicAdapter < Adapter
      DEFAULT_MODEL      = "claude-haiku-4-5-20251001".freeze
      DEFAULT_MAX_TOKENS = 4096
      DEFAULT_URL        = "https://api.anthropic.com/v1/messages".freeze
      API_VERSION        = "2023-06-01".freeze

      class APIError < StandardError
        attr_reader :status, :body
        def initialize(status, body)
          @status = status
          @body   = body
          super("Anthropic API error #{status}: #{body.to_s.slice(0, 500)}")
        end
      end

      attr_reader :logger

      def initialize(
        api_key: ENV["ANTHROPIC_API_KEY"],
        model: DEFAULT_MODEL,
        max_tokens: DEFAULT_MAX_TOKENS,
        url: DEFAULT_URL,
        http_client: nil,
        max_retries: 3,
        logger: Rails.logger,
        name: :anthropic
      )
        raise ArgumentError, "api_key is required" if api_key.nil? || api_key.empty?

        @api_key     = api_key
        @model       = model
        @max_tokens  = max_tokens
        @url         = url
        @http        = http_client || method(:default_http_post)
        @max_retries = max_retries
        @logger      = logger
        @name        = name
      end

      def start_turn(system:, user:, tools:)
        AnthropicTurn.new(
          adapter: self,
          system:  system,
          user:    user,
          tools:   tools,
          logger:  logger
        )
      end

      def complete(system:, user:)
        response = post_messages(
          system:   system,
          messages: [ { "role" => "user", "content" => user } ],
          tools:    nil
        )
        extract_text(response)
      end

      # Shorthand for single-prompt completions. Matches the `.call(prompt)`
      # shape that some legacy callers use; new code should prefer .complete.
      def call(prompt)
        complete(system: "", user: prompt)
      end

      # Public so AnthropicTurn can call back in. Not exposed to tools/callers.
      #
      # Prompt caching: places up to TWO cache_control: ephemeral breakpoints.
      #   1. On the static head (last tool with tools, or system without).
      #      Cache key = system + tools, stable across every reasoning-loop
      #      call in the session.
      #   2. On the last message in the messages array. Cache key extends to
      #      the conversation state. Within a single reasoning loop's tool-use
      #      round-trips, each new call adds an assistant_response + tool_result
      #      to messages; the previous extension-cache hits everything up
      #      through the prior turn, only the new pair is fresh. Saves the
      #      "extension cache write" tax (~5-7K tokens at 1.25× input cost)
      #      that Anthropic was implicitly charging on every inner-loop call.
      # Cached reads cost ~10% of normal input; cache writes cost ~25% extra
      # on the first call.
      def post_messages(system:, messages:, tools: nil)
        payload = {
          "model"      => @model,
          "max_tokens" => @max_tokens,
          "messages"   => mark_last_message_for_cache(messages)
        }

        has_system = system.is_a?(String) && !system.empty?
        has_tools  = tools.is_a?(Array)   && !tools.empty?

        if has_tools
          # End-of-tools breakpoint covers system + tools (the static head).
          # System stays as a plain string — it sits inside the cached prefix.
          payload["system"] = system if has_system
          payload["tools"]  = mark_last_tool_for_cache(tools)
        elsif has_system
          # No tools — cache the system message itself. Must be array form
          # for cache_control to apply.
          payload["system"] = wrap_system_for_cache(system)
        end

        with_retries { call_api(payload) }
      end

      private

      def mark_last_tool_for_cache(tools)
        return tools if tools.last.is_a?(Hash) && tools.last["cache_control"]
        marked = tools.dup
        marked[-1] = marked.last.merge("cache_control" => { "type" => "ephemeral" })
        marked
      end

      # Marks the last message's last content block with cache_control.
      # Handles both content shapes Anthropic accepts:
      #   - string content (user messages with plain text)  → wrap to array form
      #   - array of content blocks (tool_use, tool_result, etc.) → mark last
      # Skips marking when the messages array is too small to be worth caching
      # (the prompt cache minimum is 1024 tokens; a single short user message
      # won't benefit and the cache_control just adds noise).
      def mark_last_message_for_cache(messages)
        return messages if messages.empty?

        last = messages.last
        return messages if last.nil?
        return messages if last.is_a?(Hash) && last["cache_control"]

        marked = messages.dup
        last_msg = last.dup

        case last_msg["content"]
        when String
          last_msg["content"] = [
            { "type" => "text", "text" => last_msg["content"], "cache_control" => { "type" => "ephemeral" } }
          ]
        when Array
          content = last_msg["content"].dup
          last_block = content.last
          if last_block.is_a?(Hash) && !last_block["cache_control"]
            content[-1] = last_block.merge("cache_control" => { "type" => "ephemeral" })
            last_msg["content"] = content
          end
        end

        marked[-1] = last_msg
        marked
      end

      def wrap_system_for_cache(system_text)
        [
          { "type" => "text", "text" => system_text, "cache_control" => { "type" => "ephemeral" } }
        ]
      end

      def call_api(payload)
        body = JSON.generate(payload)
        headers = {
          "x-api-key"         => @api_key,
          "anthropic-version" => API_VERSION,
          "content-type"      => "application/json"
        }

        log_request(payload, body.bytesize)
        response = ::Harness::Timing.measure(adapter: @name, logger: logger) do
          @http.call(url: @url, headers: headers, body: body)
        end
        status   = response.fetch(:status)
        raw      = response.fetch(:body)

        case status
        when 200
          parsed = JSON.parse(raw)
          log_response(parsed, raw.bytesize)
          ::Harness::CostTracker.record(model: @model, usage: parsed["usage"]) if defined?(::Harness::CostTracker)
          parsed
        when 429, 500..599
          raise APIError.new(status, raw)
        else
          logger.error { "[AnthropicAdapter] non-retryable error #{status}: #{raw.to_s.slice(0, 500)}" }
          raise APIError.new(status, raw)
        end
      end

      # Pretty-print outbound payload at debug. The leading ▸▸▸ glyphs make
      # outbound vs inbound visually scannable in a stream of mixed log lines.
      def log_request(payload, bytes)
        logger.debug do
          banner = "▸▸▸ REQUEST  model=#{@model}  bytes=#{bytes}"
          "[AnthropicAdapter]\n#{banner}\n#{JSON.pretty_generate(payload)}\n▸▸▸ END REQUEST"
        end
      end

      # Pretty-print inbound payload at debug. ◂◂◂ for inbound. Stop reason is
      # surfaced in the banner because it's the single most useful signal at a
      # glance (end_turn / tool_use / max_tokens).
      def log_response(payload, bytes)
        logger.debug do
          stop   = payload["stop_reason"]
          usage  = payload["usage"]
          banner = "◂◂◂ RESPONSE  stop=#{stop}  bytes=#{bytes}  usage=#{usage&.to_json}"
          "[AnthropicAdapter]\n#{banner}\n#{JSON.pretty_generate(payload)}\n◂◂◂ END RESPONSE"
        end
      end

      def with_retries
        attempt = 0
        begin
          attempt += 1
          yield
        rescue APIError => e
          if retryable?(e.status) && attempt <= @max_retries
            sleep_time = 0.5 * (2 ** (attempt - 1))
            logger.warn { "[AnthropicAdapter] retry #{attempt}/#{@max_retries} after #{sleep_time}s (status=#{e.status})" }
            sleep(sleep_time)
            retry
          end
          raise
        end
      end

      def retryable?(status)
        status == 429 || (500..599).cover?(status)
      end

      def extract_text(response)
        Array(response["content"])
          .select { |b| b["type"] == "text" }
          .map { |b| b["text"] }
          .join
      end

      def default_http_post(url:, headers:, body:)
        uri = URI(url)
        req = Net::HTTP::Post.new(uri)
        headers.each { |k, v| req[k] = v }
        req.body = body

        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.read_timeout = 120
          http.open_timeout = 30
          http.request(req)
        end

        { status: res.code.to_i, body: res.body }
      end
    end
  end
end
