require "rails_helper"

RSpec.describe Harness::LLM::AnthropicAdapter do
  # Stub HTTP client: a recording callable that returns scripted responses.
  # Each .call(url:, headers:, body:) consumes the next scripted response.
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
      api_key: "test-key",
      http_client: http,
      max_retries: 1,
      logger: Logger.new(IO::NULL),
      **kwargs
    )
  end

  def msg_response(*blocks, stop_reason: "end_turn")
    {
      status: 200,
      body: JSON.generate(
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "content" => blocks,
        "stop_reason" => stop_reason
      )
    }
  end

  def text_block(text)
    { "type" => "text", "text" => text }
  end

  def tool_use_block(id:, name:, input: {})
    { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
  end

  describe "#complete (narration step)" do
    it "sends a user message and returns concatenated text" do
      http = stub_http([ msg_response(text_block("A stranger enters the bar."), text_block(" Silence falls.")) ])
      result = adapter(http).complete(system: "preamble", user: "describe the scene")

      expect(result).to eq("A stranger enters the bar. Silence falls.")
      expect(http.calls.size).to eq(1)
      body = http.calls.first[:body]
      # Without tools, the cache breakpoint goes on the system message —
      # which requires array-of-content-blocks form for cache_control to apply.
      expect(body["system"]).to eq([
        { "type" => "text", "text" => "preamble", "cache_control" => { "type" => "ephemeral" } }
      ])
      # The last user message is also marked for caching — extends the cache
      # to cover conversation state across reasoning-loop iterations. For
      # narration's single user message this is mostly inert (no follow-up
      # call to benefit), but the marker is uniform across all post_messages
      # invocations.
      expect(body["messages"]).to eq([
        { "role" => "user", "content" => [ { "type" => "text", "text" => "describe the scene", "cache_control" => { "type" => "ephemeral" } } ] }
      ])
      expect(body).not_to have_key("tools")
    end

    it "sends auth + version headers" do
      http = stub_http([ msg_response(text_block("ok")) ])
      adapter(http).complete(system: "sys", user: "u")
      headers = http.calls.first[:headers]
      expect(headers["x-api-key"]).to eq("test-key")
      expect(headers["anthropic-version"]).to eq("2023-06-01")
      expect(headers["content-type"]).to eq("application/json")
    end
  end

  describe "#start_turn (reasoning loop)" do
    let(:tools) { [ { "name" => "query_scene", "description" => "...", "input_schema" => { "type" => "object", "properties" => {}, "required" => [] } } ] }

    it "places a cache_control breakpoint on the last tool (caches system+tools static head)" do
      http = stub_http([
        msg_response(text_block("done"), stop_reason: "end_turn")
      ])
      adapter(http).start_turn(system: "sys", user: "u", tools: tools).next_tool_call

      body = http.calls.first[:body]
      expect(body["tools"].last["cache_control"]).to eq({ "type" => "ephemeral" })
      # System stays as a plain string when it's already inside the cached prefix.
      expect(body["system"]).to eq("sys")
    end

    it "handles a single tool_use → result → end_turn round trip" do
      http = stub_http([
        msg_response(tool_use_block(id: "t1", name: "query_scene", input: {}), stop_reason: "tool_use"),
        msg_response(text_block("done thinking"), stop_reason: "end_turn")
      ])
      turn = adapter(http).start_turn(system: "sys", user: "what's here?", tools: tools)

      expect(turn.complete?).to be(false)
      call = turn.next_tool_call
      expect(call.name).to eq("query_scene")

      turn.feed_result({ "location" => { "name" => "Tavern" } })
      expect(turn.complete?).to be(true)
      expect(turn.next_tool_call).to be_nil

      # Two API calls: initial, then follow-up with tool_result
      expect(http.calls.size).to eq(2)
      follow_up = http.calls.last[:body]
      tool_result_msg = follow_up["messages"].last
      expect(tool_result_msg["role"]).to eq("user")
      expect(tool_result_msg["content"].first["type"]).to eq("tool_result")
      expect(tool_result_msg["content"].first["tool_use_id"]).to eq("t1")

      # The last content block of the last message also gets a cache_control
      # marker — extends the cache to include the conversation state so the
      # NEXT inner-loop call (if any) reads it instead of re-writing it.
      expect(tool_result_msg["content"].last["cache_control"]).to eq({ "type" => "ephemeral" })
    end

    it "handles multiple tool_use blocks in one response (batched results)" do
      http = stub_http([
        msg_response(
          tool_use_block(id: "a", name: "query_scene", input: {}),
          tool_use_block(id: "b", name: "query_character", input: { "character_id" => 5 }),
          stop_reason: "tool_use"
        ),
        msg_response(text_block("all set"), stop_reason: "end_turn")
      ])
      turn = adapter(http).start_turn(system: "sys", user: "dig in", tools: tools)

      # Resolver pulls them one at a time, feeds results one at a time.
      c1 = turn.next_tool_call
      expect(c1.name).to eq("query_scene")
      turn.feed_result({ "location" => "Tavern" })
      expect(http.calls.size).to eq(1)  # no roundtrip yet — queue not drained

      c2 = turn.next_tool_call
      expect(c2.name).to eq("query_character")
      expect(c2.args).to eq({ "character_id" => 5 })
      turn.feed_result({ "name" => "Maren" })

      # Queue drained → follow-up fires in one batch
      expect(http.calls.size).to eq(2)
      batch = http.calls.last[:body]["messages"].last["content"]
      expect(batch.size).to eq(2)
      expect(batch.map { |b| b["tool_use_id"] }).to eq([ "a", "b" ])

      expect(turn.complete?).to be(true)
    end

    it "handles sequential tool_use across multiple API roundtrips" do
      http = stub_http([
        msg_response(tool_use_block(id: "t1", name: "query_scene"), stop_reason: "tool_use"),
        msg_response(tool_use_block(id: "t2", name: "query_character", input: { "character_id" => 1 }), stop_reason: "tool_use"),
        msg_response(text_block("done"), stop_reason: "end_turn")
      ])
      turn = adapter(http).start_turn(system: "sys", user: "go", tools: tools)

      turn.feed_result({ "location" => "T" }) if turn.next_tool_call
      turn.feed_result({ "name" => "F" }) if turn.next_tool_call

      expect(turn.complete?).to be(true)
      expect(http.calls.size).to eq(3)
    end

    it "starts complete? = false until fetch_next says stop_reason != tool_use" do
      http = stub_http([ msg_response(text_block("no tools needed"), stop_reason: "end_turn") ])
      turn = adapter(http).start_turn(system: "sys", user: "hi", tools: tools)
      expect(turn.complete?).to be(true)
      expect(turn.next_tool_call).to be_nil
      expect(turn.final_text).to eq("no tools needed")
    end

    it "serializes hash tool results as JSON" do
      http = stub_http([
        msg_response(tool_use_block(id: "x", name: "query_scene"), stop_reason: "tool_use"),
        msg_response(text_block("ok"), stop_reason: "end_turn")
      ])
      turn = adapter(http).start_turn(system: "s", user: "u", tools: tools)
      turn.next_tool_call
      turn.feed_result({ "foo" => "bar" })

      sent = http.calls.last[:body]["messages"].last["content"].first["content"]
      expect(sent).to eq('{"foo":"bar"}')
    end

    it "passes string tool results through verbatim" do
      http = stub_http([
        msg_response(tool_use_block(id: "x", name: "query_scene"), stop_reason: "tool_use"),
        msg_response(text_block("ok"), stop_reason: "end_turn")
      ])
      turn = adapter(http).start_turn(system: "s", user: "u", tools: tools)
      turn.next_tool_call
      turn.feed_result("plain string result")

      sent = http.calls.last[:body]["messages"].last["content"].first["content"]
      expect(sent).to eq("plain string result")
    end
  end

  describe "retry behavior" do
    it "retries on 429 and succeeds" do
      http = stub_http([
        { status: 429, body: "rate limited" },
        msg_response(text_block("ok"))
      ])
      a = adapter(http, max_retries: 2)
      allow(a).to receive(:sleep)
      expect(a.complete(system: "s", user: "u")).to eq("ok")
      expect(http.calls.size).to eq(2)
    end

    it "retries on 500 and succeeds" do
      http = stub_http([
        { status: 503, body: "upstream down" },
        msg_response(text_block("ok"))
      ])
      a = adapter(http, max_retries: 2)
      allow(a).to receive(:sleep)
      expect(a.complete(system: "s", user: "u")).to eq("ok")
    end

    it "raises after exhausting retries on 429" do
      http = stub_http([
        { status: 429, body: "x" },
        { status: 429, body: "x" },
        { status: 429, body: "x" }
      ])
      a = adapter(http, max_retries: 2)
      allow(a).to receive(:sleep)
      expect { a.complete(system: "s", user: "u") }.to raise_error(described_class::APIError, /429/)
    end

    it "does not retry on 401" do
      http = stub_http([ { status: 401, body: "bad key" } ])
      a = adapter(http, max_retries: 3)
      allow(a).to receive(:sleep)
      expect { a.complete(system: "s", user: "u") }.to raise_error(described_class::APIError, /401/)
      expect(http.calls.size).to eq(1)
    end

    it "does not retry on 400" do
      http = stub_http([ { status: 400, body: "bad request" } ])
      a = adapter(http, max_retries: 3)
      allow(a).to receive(:sleep)
      expect { a.complete(system: "s", user: "u") }.to raise_error(described_class::APIError, /400/)
      expect(http.calls.size).to eq(1)
    end
  end

  describe "construction" do
    it "requires an api_key" do
      expect {
        described_class.new(api_key: nil)
      }.to raise_error(ArgumentError, /api_key/)
    end

    it "reads api_key from ENV by default" do
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("env-key")
      expect { described_class.new(http_client: ->(**) {}) }.not_to raise_error
    end
  end
end
