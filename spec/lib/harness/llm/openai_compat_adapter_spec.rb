require "rails_helper"

RSpec.describe Harness::LLM::OpenAICompatAdapter do
  def stub_http(responses)
    calls = []
    queue = responses.dup
    client = ->(url:, headers:, body:) {
      calls << { url: url, headers: headers, body: JSON.parse(body) }
      raise "stub_http ran out of scripted responses" if queue.empty?
      queue.shift
    }
    client.define_singleton_method(:calls) { calls }
    client
  end

  def adapter(http, **kwargs)
    described_class.new(
      base_url:    "http://localhost:8080/v1",
      api_key:     "test-key",
      model:       "test-model",
      http_client: http,
      max_retries: 1,
      logger:      Logger.new(IO::NULL),
      **kwargs
    )
  end

  def chat_response(message, finish_reason: "stop")
    {
      status: 200,
      body: JSON.generate(
        "id" => "chatcmpl-1",
        "object" => "chat.completion",
        "choices" => [ {
          "index" => 0,
          "message" => message,
          "finish_reason" => finish_reason
        } ]
      )
    }
  end

  def text_message(text, reasoning: nil)
    msg = { "role" => "assistant", "content" => text }
    msg["reasoning_content"] = reasoning if reasoning
    msg
  end

  def tool_call_message(id:, name:, arguments: "{}", text: "")
    {
      "role" => "assistant",
      "content" => text,
      "tool_calls" => [ {
        "id" => id,
        "type" => "function",
        "function" => { "name" => name, "arguments" => arguments }
      } ]
    }
  end

  describe "#complete (narration step)" do
    it "sends a system + user message and returns the content string" do
      http = stub_http([ chat_response(text_message("A stranger enters the bar.")) ])
      result = adapter(http).complete(system: "preamble", user: "describe the scene")

      expect(result).to eq("A stranger enters the bar.")
      expect(http.calls.size).to eq(1)
      body = http.calls.first[:body]
      expect(body["messages"]).to eq([
        { "role" => "system", "content" => "preamble" },
        { "role" => "user",   "content" => "describe the scene" }
      ])
      expect(body).not_to have_key("tools")
      # think_in_complete defaults false → enable_thinking flag passed through
      expect(body["chat_template_kwargs"]).to eq({ "enable_thinking" => false })
    end

    it "omits the system message when empty" do
      http = stub_http([ chat_response(text_message("ok")) ])
      adapter(http).complete(system: "", user: "u")
      body = http.calls.first[:body]
      expect(body["messages"]).to eq([ { "role" => "user", "content" => "u" } ])
    end

    it "sends bearer auth and content-type headers" do
      http = stub_http([ chat_response(text_message("ok")) ])
      adapter(http).complete(system: "sys", user: "u")
      headers = http.calls.first[:headers]
      expect(headers["authorization"]).to eq("Bearer test-key")
      expect(headers["content-type"]).to eq("application/json")
    end

    it "posts to /chat/completions under the configured base_url" do
      http = stub_http([ chat_response(text_message("ok")) ])
      adapter(http).complete(system: "", user: "u")
      expect(http.calls.first[:url]).to eq("http://localhost:8080/v1/chat/completions")
    end
  end

  describe "#start_turn (reasoning loop)" do
    let(:tools) {
      [ {
        "name" => "query_scene",
        "description" => "look around",
        "input_schema" => { "type" => "object", "properties" => {}, "required" => [] }
      } ]
    }

    it "translates Anthropic-shape tools to OpenAI function shape" do
      http = stub_http([ chat_response(text_message("done")) ])
      adapter(http).start_turn(system: "sys", user: "u", tools: tools).next_tool_call

      body = http.calls.first[:body]
      expect(body["tools"]).to eq([
        {
          "type" => "function",
          "function" => {
            "name" => "query_scene",
            "description" => "look around",
            "parameters" => { "type" => "object", "properties" => {}, "required" => [] }
          }
        }
      ])
    end

    it "passes enable_thinking=false by default for the reasoning loop" do
      # Thinking is OFF by default at local-inference speeds — see the
      # adapter's class doc for the rationale (think output dominates wall
      # time at ~35 tok/s; the reasoning prompt's structural patterns give
      # the model enough planning surface without <think>).
      http = stub_http([ chat_response(text_message("done")) ])
      adapter(http).start_turn(system: "sys", user: "u", tools: tools)
      body = http.calls.first[:body]
      expect(body["chat_template_kwargs"]).to eq({ "enable_thinking" => false })
    end

    it "honors think_in_reasoning: true when explicitly enabled" do
      http = stub_http([ chat_response(text_message("done")) ])
      adapter(http, think_in_reasoning: true).start_turn(system: "sys", user: "u", tools: tools)
      body = http.calls.first[:body]
      expect(body["chat_template_kwargs"]).to eq({ "enable_thinking" => true })
    end

    it "handles a single tool_call → result → stop round trip" do
      args = JSON.generate({ "topic" => "thieves" })
      http = stub_http([
        chat_response(tool_call_message(id: "call_1", name: "query_scene", arguments: args), finish_reason: "tool_calls"),
        chat_response(text_message("scene described"))
      ])

      turn = adapter(http).start_turn(system: "sys", user: "look", tools: tools)
      call = turn.next_tool_call
      expect(call.name).to eq("query_scene")
      expect(call.args).to eq({ "topic" => "thieves" })
      expect(turn.complete?).to eq(false)

      turn.feed_result({ "result" => "you see a tavern" })
      expect(turn.complete?).to eq(true)
      expect(turn.final_text).to eq("scene described")

      # Second call: assistant tool_call message echoed, tool result message
      # sent with role=tool and the original tool_call_id.
      body2 = http.calls[1][:body]
      msgs  = body2["messages"]
      assistant_echo = msgs.find { |m| m["role"] == "assistant" && m["tool_calls"] }
      expect(assistant_echo).not_to be_nil
      expect(assistant_echo["tool_calls"].first["id"]).to eq("call_1")

      tool_result = msgs.last
      expect(tool_result["role"]).to eq("tool")
      expect(tool_result["tool_call_id"]).to eq("call_1")
      expect(JSON.parse(tool_result["content"])).to eq({ "result" => "you see a tavern" })
    end

    it "handles multiple tool_calls in one response (drains queue before next fetch)" do
      msg = {
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          { "id" => "a", "type" => "function", "function" => { "name" => "query_scene",  "arguments" => "{}" } },
          { "id" => "b", "type" => "function", "function" => { "name" => "query_character", "arguments" => "{\"id\":7}" } }
        ]
      }
      http = stub_http([
        chat_response(msg, finish_reason: "tool_calls"),
        chat_response(text_message("ok"))
      ])

      turn = adapter(http).start_turn(system: "", user: "u", tools: tools)

      first = turn.next_tool_call
      expect(first.name).to eq("query_scene")
      turn.feed_result("{}")

      # Only one HTTP call so far — queue not drained, no fetch yet.
      expect(http.calls.size).to eq(1)

      second = turn.next_tool_call
      expect(second.name).to eq("query_character")
      expect(second.args).to eq({ "id" => 7 })
      turn.feed_result("{}")

      # Second fetch fires after both tools are answered.
      expect(http.calls.size).to eq(2)
      expect(turn.complete?).to eq(true)
    end

    it "captures reasoning_content separately from final_text" do
      http = stub_http([
        chat_response(text_message("the answer", reasoning: "thinking out loud"))
      ])
      turn = adapter(http).start_turn(system: "", user: "u", tools: [])
      turn.next_tool_call
      expect(turn.final_text).to eq("the answer")
      expect(turn.final_thoughts).to eq("thinking out loud")
    end

    it "tolerates malformed tool arg JSON (returns empty hash, logs warn)" do
      http = stub_http([
        chat_response(tool_call_message(id: "call_1", name: "query_scene", arguments: "not-json"), finish_reason: "tool_calls"),
        chat_response(text_message("done"))
      ])
      turn = adapter(http).start_turn(system: "", user: "u", tools: tools)
      call = turn.next_tool_call
      expect(call.args).to eq({})
      turn.feed_result("{}")
      expect(turn.complete?).to eq(true)
    end
  end

  describe "#display_model" do
    def stub_get(responses)
      queue = responses.dup
      ->(url:) {
        raise "stub_get out of responses" if queue.empty?
        queue.shift
      }
    end

    it "returns the loaded model name from llama.cpp's /v1/models shape, stripping .gguf" do
      get = stub_get([ {
        status: 200,
        body: JSON.generate("models" => [ { "name" => "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" } ])
      } ])
      a = adapter(stub_http([]), http_get_client: get, model: "configured-fallback")
      expect(a.display_model).to eq("Qwen3.6-35B-A3B-UD-Q4_K_XL")
    end

    it "returns the model id from OpenAI / vLLM shape" do
      get = stub_get([ {
        status: 200,
        body: JSON.generate("data" => [ { "id" => "Qwen/Qwen3.6-35B-A3B-Instruct" } ])
      } ])
      a = adapter(stub_http([]), http_get_client: get)
      expect(a.display_model).to eq("Qwen/Qwen3.6-35B-A3B-Instruct")
    end

    it "caches across calls (only one /v1/models GET)" do
      calls = 0
      get = ->(url:) {
        calls += 1
        { status: 200, body: JSON.generate("data" => [ { "id" => "x" } ]) }
      }
      a = adapter(stub_http([]), http_get_client: get)
      a.display_model
      a.display_model
      a.display_model
      expect(calls).to eq(1)
    end

    it "falls back to the configured model when the server is unreachable" do
      get = ->(url:) { raise Errno::ECONNREFUSED }
      a = adapter(stub_http([]), http_get_client: get, model: "configured-fallback")
      expect(a.display_model).to eq("configured-fallback")
    end

    it "falls back when /v1/models returns an unexpected shape" do
      get = stub_get([ { status: 200, body: '{"weird": "response"}' } ])
      a = adapter(stub_http([]), http_get_client: get, model: "configured-fallback")
      expect(a.display_model).to eq("configured-fallback")
    end

    it "falls back to 'local' when both lookup and @model are unset" do
      get = ->(url:) { raise Errno::ECONNREFUSED }
      a = adapter(stub_http([]), http_get_client: get, model: nil)
      expect(a.display_model).to eq("local")
    end
  end

  describe "error handling" do
    it "raises APIError on non-retryable status" do
      http = stub_http([ { status: 400, body: '{"error":"bad request"}' } ])
      expect { adapter(http).complete(system: "", user: "u") }
        .to raise_error(Harness::LLM::OpenAICompatAdapter::APIError, /400/)
    end

    it "retries on 5xx then succeeds" do
      http = stub_http([
        { status: 503, body: "{}" },
        chat_response(text_message("ok"))
      ])
      result = adapter(http, max_retries: 1).complete(system: "", user: "u")
      expect(result).to eq("ok")
      expect(http.calls.size).to eq(2)
    end
  end

  describe "#embed" do
    def embed_response(vectors)
      { status: 200,
        body: JSON.generate("object" => "list",
          "data" => vectors.each_with_index.map { |v, i| { "index" => i, "object" => "embedding", "embedding" => v } }) }
    end

    it "returns a single vector for a String input and posts to /embeddings" do
      http = stub_http([ embed_response([ [ 0.1, 0.2, 0.3 ] ]) ])
      out  = adapter(http).embed("hello")
      expect(out).to eq([ 0.1, 0.2, 0.3 ])
      expect(http.calls.first[:url]).to end_with("/v1/embeddings")
      expect(http.calls.first[:body]).to eq("model" => "test-model", "input" => [ "hello" ])
    end

    it "returns vectors in input order for an Array input (mget batch)" do
      http = stub_http([ embed_response([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ]) ])
      out  = adapter(http).embed([ "a", "b" ])
      expect(out).to eq([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ])
      expect(http.calls.size).to eq(1)
    end

    it "re-sorts by the response index (never trusts array order)" do
      scrambled = { status: 200, body: JSON.generate("data" => [
        { "index" => 1, "embedding" => [ 0.0, 1.0 ] },
        { "index" => 0, "embedding" => [ 1.0, 0.0 ] }
      ]) }
      out = adapter(stub_http([ scrambled ])).embed([ "a", "b" ])
      expect(out).to eq([ [ 1.0, 0.0 ], [ 0.0, 1.0 ] ])
    end

    it "chunks a large array to EMBED_BATCH per request" do
      described_class::EMBED_BATCH.then do |cap|
        texts = Array.new(cap + 5) { |i| "t#{i}" }
        http  = stub_http([
          embed_response(Array.new(cap) { [ 0.0 ] }),
          embed_response(Array.new(5)   { [ 0.0 ] })
        ])
        out = adapter(http).embed(texts)
        expect(out.size).to eq(cap + 5)
        expect(http.calls.size).to eq(2)
        expect(http.calls.first[:body]["input"].size).to eq(cap)
        expect(http.calls.last[:body]["input"].size).to eq(5)
      end
    end

    it "returns [] for an empty array without calling the server" do
      http = stub_http([])
      expect(adapter(http).embed([])).to eq([])
      expect(http.calls).to be_empty
    end
  end
end
