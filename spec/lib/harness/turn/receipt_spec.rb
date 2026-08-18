require "rails_helper"

RSpec.describe Harness::Turn::Receipt do
  let(:city) { Location.create!(name: "Saltmere") }

  after do
    described_class.disable!
    Thread.current[described_class::TURN_KEY] = nil
  end

  def transcript(input: "hello")
    Harness::Turn::Transcript.new(input: input)
  end

  it "captures creates, constant updates, and destroys between begin and finalize" do
    city # materialize the location before the turn opens
    described_class.enable!
    described_class.begin_turn!(game_time: 100)

    npc = Npc.create!(name: "Maren", location: city, current_hp: 5, max_hp: 5)
    npc.update!(current_hp: 2)
    npc.destroy!

    receipt = described_class.finalize!(transcript: transcript, game_time: 130)
    actions = receipt["db_writes"].map { |w| w["action"] }
    expect(actions).to eq(%w[create update destroy])
    expect(receipt["db_writes"][1]["changes"]).to eq({ "current_hp" => [ 5, 2 ] })
    expect(receipt["db_writes"].map { |w| w["name"] }.uniq).to eq([ "Maren" ])
    expect(receipt["clock"]).to eq({ "before" => 100, "after" => 130 })
  end

  it "elides prose values and skips timestamp/embedding columns" do
    described_class.enable!
    described_class.begin_turn!
    loc = Location.create!(name: "The Mill")
    loc.update!(description: "a" * 200)
    receipt = described_class.finalize!(transcript: transcript)
    update = receipt["db_writes"].find { |w| w["action"] == "update" }
    expect(update["changes"]).to eq({ "description" => [ nil, "…" ] })
  end

  it "ignores writes when no turn is open, and update_column always" do
    described_class.enable!
    npc = Npc.create!(name: "Quiet", location: city) # before begin_turn!
    described_class.begin_turn!
    npc.update_column(:current_hp, 1)
    receipt = described_class.finalize!(transcript: transcript)
    expect(receipt["db_writes"]).to eq([])
  end

  it "is inert when disabled" do
    described_class.begin_turn!
    Npc.create!(name: "Ghost", location: city)
    expect(described_class.finalize!(transcript: transcript)).to be_nil
  end

  it "carries the transcript's trace: runners, tool calls with scalar args, errors, notices" do
    described_class.enable!
    described_class.begin_turn!
    t = transcript(input: "buy a sword")
    t.runners_ran = %w[conversation]
    t.record_tool_calls([
      { "name" => "transfer_coins", "args" => { "amount" => 5, "note" => "b" * 100 }, "result" => { "ok" => true } },
      { "name" => "buy_item", "args" => {}, "result" => { "error" => "not enough coins" } }
    ])
    t.notice = "engine hiccup"
    receipt = described_class.finalize!(transcript: t)

    expect(receipt["input"]).to eq("buy a sword")
    expect(receipt["runners"]).to eq(%w[conversation])
    expect(receipt["tool_calls"][0]).to eq({ "name" => "transfer_coins", "args" => { "amount" => 5, "note" => "…" } })
    expect(receipt["tool_calls"][1]["error"]).to eq("not enough coins")
    expect(receipt["notice"]).to eq("engine hiccup")
    expect(described_class.last).to equal(receipt)
  end
end
