require "rails_helper"

# End-to-end: Turn::Loop running against AnthropicAdapter with a stub HTTP
# client. Proves the adapter-loop interface works against a real adapter
# implementation, not just the fake. Uses no real network.
RSpec.describe "Turn::Loop + AnthropicAdapter" do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Dockside Inn", parent: city) }
  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let!(:player) { Player.create!(name: "Hero", subrole: "adventurer", location: tavern) }
  let(:context) { Harness::Turn::Context.new(player_location: tavern) }

  def stub_http(responses)
    queue = responses.dup
    ->(url:, headers:, body:) {
      raise "no more stubbed responses" if queue.empty?
      queue.shift
    }
  end

  def msg(*blocks, stop_reason: "end_turn")
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

  def tool_use(id:, name:, input: {})
    { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
  end

  def text(t)
    { "type" => "text", "text" => t }
  end

  it "runs a full turn: reasoning-loop tool call → narration → TurnLog" do
    maren  # ensure character exists

    http = stub_http([
      # Scene entry: InternalState generator runs once, returns mood prose
      # for Maren (the only NPC at this scene).
      msg(text({ "internal_states" => { "Maren" => "Maren polishes a mug without looking up; he's tired and the morning has been long." } }.to_json)),
      # Reasoning loop: model calls query_scene, then stops
      msg(tool_use(id: "t1", name: "query_scene", input: {}), stop_reason: "tool_use"),
      msg(text("I have seen the scene."), stop_reason: "end_turn"),
      # Narration step
      msg(text("The tavern is dim; Maren polishes a mug without looking up."))
    ])

    adapter = Harness::LLM::AnthropicAdapter.new(
      api_key: "test-key",
      http_client: http,
      max_retries: 0,
      logger: Logger.new(IO::NULL)
    )

    # This proves the AGENTIC loop ↔ real-adapter interface; the HTTP queue is
    # written for that path. The state-machine path (dispatcher + runners) is
    # covered by executor_spec with a stubbed planner.
    loop = Harness::Turn::Loop.new(
      adapter: adapter,
      context: context,
      mode:    :agentic,
      logger:  Logger.new(IO::NULL)
    )

    transcript = loop.run_turn(input: "look around")

    expect(transcript.narration).to match(/tavern is dim/)
    expect(transcript.tool_calls.size).to eq(1)
    expect(transcript.tool_calls.first["name"]).to eq("query_scene")
    expect(transcript.tool_calls.first["result"]["present_characters"].first["name"]).to eq("Maren")

    row = TurnLog.last
    expect(row.narration).to match(/tavern is dim/)
    expect(row.reasoning_tool_calls.first["name"]).to eq("query_scene")
  end
end
