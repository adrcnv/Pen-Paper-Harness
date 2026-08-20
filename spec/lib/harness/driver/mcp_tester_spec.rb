require "rails_helper"
require "tmpdir"

RSpec.describe Harness::Driver::McpTester do
  let(:city)   { Location.create!(name: "Saltmere", x: 1.0, y: 1.0) }
  let(:player) { Player.create!(name: "Tester", location: city, character_class: "fighter", level: 1) }

  let(:stub) {
    StubLLM.new { |prompt|
      if prompt.include?("\"plan\"") || prompt.include?("PLAN")
        { "reasoning" => "look", "plan" => [ { "reason" => "look around", "runner" => "inspection", "args" => {} } ] }.to_json
      else
        "The room sits quiet."
      end
    }
  }

  let(:run_dir) { Dir.mktmpdir("mcp-tester-spec") }
  # No worldgen in specs: the factory attaches a stub-backed session to the
  # prepared world instead (snapshot_dir deliberately unset — file swaps
  # don't mix with transactional fixtures).
  let(:factory) {
    ->(seed, _snapshot_dir) {
      Harness::Driver::Session.new(seed: seed, grunt: stub, nuance: stub,
                                   logger: Logger.new(IO::NULL)).continue!
    }
  }
  let(:tester) { described_class.new(run_dir: run_dir, logger: Logger.new(IO::NULL), session_factory: factory) }

  before { player }
  after do
    Harness::Turn::Receipt.disable!
    FileUtils.remove_entry(run_dir)
  end

  it "refuses every verb before start_scenario" do
    expect { tester.play_turn(input: "look") }.to raise_error(/start_scenario/)
    expect { tester.flag(observation: "x") }.to raise_error(/start_scenario/)
  end

  it "start_scenario reports the world; play_turn returns the player view only" do
    started = tester.start_scenario(seed: 7)
    expect(started).to include("status" => "world ready", "seed" => 7, "location" => "Saltmere")

    result = tester.play_turn(input: "look around")
    expect(result).to include("narration", "game_time", "location", "turn")
    expect(result).not_to have_key("receipt")
    expect(result["turn"]).to eq(1)
  end

  it "flag bundles evidence server-side into flags.jsonl" do
    tester.start_scenario(seed: 7)
    tester.play_turn(input: "look around")
    tester.flag(observation: "the turn came back empty")

    lines = File.readlines(File.join(run_dir, "flags.jsonl"))
    expect(lines.size).to eq(1)
    entry = JSON.parse(lines.first)
    expect(entry["observation"]).to eq("the turn came back empty")
    expect(entry["at_turn"]).to eq(1)
    expect(entry["seed"]).to eq(7)
    expect(entry["transcript"].last).to include("input" => "look around")
    expect(entry["receipts"].last).to include("turn" => 1, "input" => "look around")
  end

  it "sheet and map return the player surface" do
    tester.start_scenario(seed: 7)
    sheet = tester.sheet
    expect(sheet["sheet"]).to include("── Tester the Fighter ──")
    expect(sheet["sheet"]).to include("stats:")

    result = tester.map
    expect(result.key?("map") || result.key?("note")).to be(true)
  end

  it "checkpoint records the turn; rewind rejects unknown labels" do
    tester.start_scenario(seed: 7)
    tester.play_turn(input: "look around")
    expect(tester.checkpoint(label: "here")).to include("turn" => 1)
    expect { tester.rewind(label: "nope") }.to raise_error(ArgumentError, /no checkpoint/)
  end

  it "end_scenario writes the report" do
    tester.start_scenario(seed: 7)
    tester.play_turn(input: "look around")
    tester.flag(observation: "something odd")
    ended = tester.end_scenario(recount: "walked around, one oddity", succeeded: true)
    expect(ended).to include("status" => "recorded", "flags" => 1)

    report = JSON.parse(File.read(File.join(run_dir, "report.json")))
    expect(report).to include("recount" => "walked around, one oddity",
                              "succeeded" => true, "turns" => 1, "flags" => 1, "seed" => 7)
  end
end
