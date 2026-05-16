require "rails_helper"

RSpec.describe Harness::Combat::EndOfRoundNarration do
  let(:actions) {
    [
      { "tool" => "resolve", "actor_id" => 1, "actor_name" => "Mud",
        "result" => { "outcome" => "success", "margin" => "clear", "stat" => "strength", "roll" => 17, "against" => 12, "action" => "swing the blade" } },
      { "tool" => "end_turn", "actor_id" => 7, "actor_name" => "Vek", "result" => {} }
    ]
  }

  it "calls the LLM with system + user payload and returns its prose" do
    captured = nil
    llm = StubLLM.new { |prompt| captured = prompt; "[swing the blade — Strength 17 vs 12: success, clear]\n\nYour blade lands clean across Vek's ribs." }
    out = described_class.run(round: 3, actions: actions, llm: llm)
    expect(out).to start_with("[swing the blade")
    expect(captured).to include("\"round\": 3")
    expect(captured).to include("\"actor_name\": \"Mud\"")
  end

  it "falls back to a one-line mechanical summary when LLM is nil" do
    out = described_class.run(round: 2, actions: actions, llm: nil)
    expect(out).to start_with("[Round 2]")
    expect(out).to include("Mud: resolve")
    expect(out).to include("Vek: end_turn")
  end

  it "falls back when LLM raises" do
    llm = Object.new
    def llm.complete(**); raise "boom"; end
    out = described_class.run(round: 1, actions: actions, llm: llm)
    expect(out).to start_with("[Round 1]")
  end
end
