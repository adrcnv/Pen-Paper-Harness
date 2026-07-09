require "net/http"
require "uri"
require "json"

module Harness
  module LLM
    # OpenAI Chat Completions adapter — works with any server that speaks the
    # /v1/chat/completions shape. Built for llama.cpp's `llama-server` running
    # local Qwen 3.6 (with --jinja, on by default in recent builds), but the
    # same code targets vLLM, Ollama's openai-compat endpoint, or OpenAI proper.
    #
    # Differences from AnthropicAdapter:
    #   - tools translated from Anthropic's {name, description, input_schema}
    #     to OpenAI's {type: "function", function: {name, description, parameters}}
    #   - assistant tool calls live in `message.tool_calls[]` (not content blocks)
    #   - tool results posted as their own `role: "tool"` messages (not user
    #     content blocks)
    #   - finish_reason "tool_calls" gates the loop (not stop_reason "tool_use")
    #   - no prompt-cache breakpoints (local inference is free; KV cache is
    #     the server's own concern)
    #
    # Reasoning mode (Qwen 3.6): the model emits a chain-of-thought trace in
    # `reasoning_content`, final answer in `content`. Both default OFF.
    #
    # Why off for the reasoning loop: at local-inference output speeds
    # (~35 tok/s), thinking content dominates per-call latency — a single
    # tool call routinely produces 1500-8000 tokens of `<think>` before
    # ~50-300 tokens of actual tool args. Worst case the model spins until
    # it hits max_tokens with no tool call emitted (a 4-minute no-op turn).
    # The reasoning prompt's four-pattern structural guidance
    # (CREATE/SHIFT/DEFLECT/RESOLVE) gives the model enough planning surface
    # without `<think>`. Flip back to true (constructor kwarg) if tool
    # selection quality degrades visibly in play.
    #
    # Why off for complete: narration and materializers want direct output;
    # no thinking budget needed.
    class OpenAICompatAdapter < Adapter
      DEFAULT_BASE_URL   = "http://127.0.0.1:8080/v1".freeze
      DEFAULT_MODEL      = "local".freeze
      DEFAULT_MAX_TOKENS = 8192
      # Max texts per /v1/embeddings request. llama.cpp caps a batch at its
      # --ubatch / -np window; chunk under it so a big backfill can't overflow
      # the server in one shot. Recall sends one text; capture a handful.
      EMBED_BATCH        = 64

      class APIError < StandardError
        attr_reader :status, :body
        def initialize(status, body)
          @status = status
          @body   = body
          super("OpenAI-compat API error #{status}: #{body.to_s.slice(0, 500)}")
        end
      end

      attr_reader :logger

      def initialize(
        base_url: DEFAULT_BASE_URL,
        api_key: "local",
        model: DEFAULT_MODEL,
        max_tokens: DEFAULT_MAX_TOKENS,
        http_client: nil,
        http_get_client: nil,
        max_retries: 3,
        think_in_reasoning: false,
        think_in_complete: false,
        logger: Rails.logger,
        name: :openai_compat
      )
        @base_url           = base_url.sub(%r{/+\z}, "")
        @api_key            = api_key
        @model              = model
        @max_tokens         = max_tokens
        @http               = http_client || method(:default_http_post)
        @http_get           = http_get_client
        @max_retries        = max_retries
        @think_in_reasoning = think_in_reasoning
        @think_in_complete  = think_in_complete
        @logger             = logger
        @name               = name
      end

      def start_turn(system:, user:, tools:)
        OpenAICompatTurn.new(
          adapter:         self,
          system:          system,
          user:            user,
          tools:           translate_tools(tools),
          enable_thinking: @think_in_reasoning,
          logger:          logger
        )
      end

      def complete(system:, user:)
        messages = []
        messages << { "role" => "system", "content" => system } if system.is_a?(String) && !system.empty?
        messages << { "role" => "user",   "content" => user }

        response = post_chat(messages: messages, tools: nil, enable_thinking: @think_in_complete)
        extract_text(response)
      end

      def call(prompt)
        complete(system: "", user: prompt)
      end

      # Embed text via /v1/embeddings. A String returns one vector (Array of
      # Float); an Array of Strings returns vectors in input order (mget-style).
      # An array is chunked to EMBED_BATCH per request so a large backfill can't
      # overflow the server's batch window. Raises APIError on a hard failure —
      # callers that must not fail (recall ranking) rescue and fall back.
      def embed(input)
        array = input.is_a?(Array)
        texts = (array ? input : [ input ]).map(&:to_s)
        return array ? [] : nil if texts.empty?

        vectors = texts.each_slice(EMBED_BATCH).flat_map { |slice| embed_batch(slice) }
        array ? vectors : vectors.first
      end

      # Asks the server what model is actually loaded. llama.cpp returns
      # `{models: [{name: "Qwen3.6-...gguf", ...}]}`; OpenAI / vLLM return
      # the standard `{data: [{id: "gpt-4", ...}]}` shape. Caches the result
      # so banners and logs don't keep poking the endpoint. Falls back to
      # the configured @model (or "local") if the server isn't reachable
      # or returns something unexpected — banner display is never
      # load-bearing enough to fail startup.
      def display_model
        return @display_model if defined?(@display_model)
        @display_model = fetch_loaded_model || @model || "local"
      end

      # Anti-parrot sampling: llama.cpp's DRY sampler penalizes tokens that
      # would EXTEND a sequence already present in context (prompt +
      # generation) — the weak model's verbatim copy-from-thread pathology
      # (NPCs re-reciting a prior turn's line). penalty = multiplier *
      # base^(match_len - allowed_length): allowed_length 6 leaves character
      # names (~4-6 tokens, endlessly repeated by design) essentially free
      # while crushing copied sentences; default sequence breakers
      # (newline, colon, quote, *) keep JSON scaffolding immune. llama.cpp
      # accepts these through the OpenAI-compat endpoint; a strict OpenAI
      # server would 400 on them — this adapter's deployment reality is
      # llama.cpp (the hosted path is the Anthropic adapter).
      DRY_SAMPLING = {
        "dry_multiplier"     => 0.8,
        "dry_base"           => 1.75,
        "dry_allowed_length" => 6
      }.freeze

      # Public so OpenAICompatTurn can call back in.
      def post_chat(messages:, tools: nil, enable_thinking: nil)
        payload = {
          "model"      => @model,
          "max_tokens" => @max_tokens,
          "messages"   => messages
        }.merge(DRY_SAMPLING)
        payload["tools"] = tools if tools.is_a?(Array) && !tools.empty?
        # Per-turn sampler seed (replay rig). llama.cpp honors it; servers
        # that don't just ignore the field.
        payload["seed"] = ::Harness::LLM::Seed.current if ::Harness::LLM::Seed.current
        # Strict replay: a pinned seed fixes the SAMPLER, but llama.cpp's
        # logits aren't bit-stable across KV-cache states (cache warmth
        # changes batch splits changes float rounding). Disabling prompt
        # caching forces a full re-prefill every call — identical batch
        # splits, reproducible logits — at the cost of ALL cache reuse
        # (expect several extra seconds per call). Debug-session lever;
        # both runs being compared must use it.
        payload["cache_prompt"] = false if ENV["HARNESS_STRICT_REPLAY"] == "1"

        # llama.cpp passes chat_template_kwargs through to the jinja template.
        # Qwen 3.6's template reads `enable_thinking` to gate the <think> block.
        # Servers that ignore it (vanilla OpenAI, vLLM without the flag) will
        # just drop it silently, which is the right fallback behavior.
        unless enable_thinking.nil?
          payload["chat_template_kwargs"] = { "enable_thinking" => enable_thinking }
        end

        with_retries { call_api(payload) }
      end

      private

      # GET /v1/models, return a clean model name or nil on any failure.
      # Tries OpenAI shape (data[0].id) first, then llama.cpp shape
      # (models[0].name or models[0].model). Strips the .gguf extension
      # so banners read "Qwen3.6-35B-A3B-UD-Q4_K_XL" instead of the
      # filename. Logs at debug only — a missing /v1/models endpoint is
      # not an error, some servers just don't implement it.
      def fetch_loaded_model
        response = http_get("#{@base_url}/models")
        return nil unless response.fetch(:status) == 200
        parsed = JSON.parse(response.fetch(:body))
        raw = parsed.dig("data", 0, "id") ||
              parsed.dig("models", 0, "name") ||
              parsed.dig("models", 0, "model")
        return nil unless raw.is_a?(String) && !raw.empty?
        raw.sub(/\.gguf\z/i, "")
      rescue StandardError => e
        logger.debug { "[OpenAICompatAdapter] /v1/models lookup failed: #{e.class}: #{e.message}" }
        nil
      end

      # Separate seam from @http (which is POST-only) so display_model can
      # GET /v1/models. Override via @http_get in tests to stub the model
      # lookup; production uses Net::HTTP directly with a short timeout
      # because it's a non-blocking enrichment, not a hot path.
      def http_get(url)
        return @http_get.call(url: url) if @http_get
        uri = URI(url)
        req = Net::HTTP::Get.new(uri)
        req["authorization"] = "Bearer #{@api_key}"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.read_timeout = 5
          http.open_timeout = 2
          http.request(req)
        end
        { status: res.code.to_i, body: res.body }
      end

      def translate_tools(tools)
        Array(tools).map do |t|
          {
            "type" => "function",
            "function" => {
              "name"        => t["name"],
              "description" => t["description"],
              "parameters"  => t["input_schema"] || { "type" => "object", "properties" => {} }
            }.compact
          }
        end
      end

      def call_api(payload)
        body = JSON.generate(payload)
        headers = {
          "authorization" => "Bearer #{@api_key}",
          "content-type"  => "application/json"
        }

        log_request(payload, body.bytesize)
        response = ::Harness::Timing.measure(adapter: @name, logger: logger) do
          @http.call(url: "#{@base_url}/chat/completions", headers: headers, body: body)
        end
        status   = response.fetch(:status)
        raw      = response.fetch(:body)

        case status
        when 200
          parsed = JSON.parse(raw)
          log_response(parsed, raw.bytesize)
          parsed
        when 429, 500..599
          raise APIError.new(status, raw)
        else
          logger.error { "[OpenAICompatAdapter] non-retryable error #{status}: #{raw.to_s.slice(0, 500)}" }
          raise APIError.new(status, raw)
        end
      end

      # One /v1/embeddings request for up to EMBED_BATCH texts. Returns the
      # vectors sorted by the response's `index` (input order), each a Float
      # array. Reuses the @http POST seam + retry policy.
      def embed_batch(texts)
        body = JSON.generate({ "model" => @model, "input" => texts })
        headers = {
          "authorization" => "Bearer #{@api_key}",
          "content-type"  => "application/json"
        }
        logger.debug { "[OpenAICompatAdapter] ▸ EMBED n=#{texts.size} bytes=#{body.bytesize}" }

        parsed = with_retries do
          response = ::Harness::Timing.measure(adapter: @name, logger: logger) do
            @http.call(url: "#{@base_url}/embeddings", headers: headers, body: body)
          end
          status = response.fetch(:status)
          raw    = response.fetch(:body)
          if status == 200
            JSON.parse(raw)
          else
            logger.error { "[OpenAICompatAdapter] embeddings error #{status}: #{raw.to_s.slice(0, 300)}" } unless retryable?(status)
            raise APIError.new(status, raw)
          end
        end

        Array(parsed["data"])
          .sort_by { |d| d["index"].to_i }
          .map { |d| Array(d["embedding"]).map(&:to_f) }
      end

      def log_request(payload, bytes)
        logger.debug do
          banner = "▸▸▸ REQUEST  model=#{@model}  bytes=#{bytes}"
          "[OpenAICompatAdapter]\n#{banner}\n#{JSON.pretty_generate(payload)}\n▸▸▸ END REQUEST"
        end
      end

      def log_response(payload, bytes)
        logger.debug do
          finish = payload.dig("choices", 0, "finish_reason")
          usage  = payload["usage"]
          banner = "◂◂◂ RESPONSE  finish=#{finish}  bytes=#{bytes}  usage=#{usage&.to_json}"
          "[OpenAICompatAdapter]\n#{banner}\n#{JSON.pretty_generate(payload)}\n◂◂◂ END RESPONSE"
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
            logger.warn { "[OpenAICompatAdapter] retry #{attempt}/#{@max_retries} after #{sleep_time}s (status=#{e.status})" }
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
        response.dig("choices", 0, "message", "content").to_s
      end

      def default_http_post(url:, headers:, body:)
        uri = URI(url)
        req = Net::HTTP::Post.new(uri)
        headers.each { |k, v| req[k] = v }
        req.body = body

        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.read_timeout = 600  # local inference can be slow under heavy CPU offload
          http.open_timeout = 30
          http.request(req)
        end

        { status: res.code.to_i, body: res.body }
      end
    end
  end
end
