require "rails_helper"

RSpec.describe Harness::CostTracker do
  before do
    described_class.reset_session!
  end

  describe ".record + cost computation" do
    it "computes cost from Anthropic-shape usage hash with Haiku 4.5 pricing" do
      entry = described_class.record(
        model: "claude-haiku-4-5-20251001",
        usage: {
          "input_tokens"                => 1000,
          "cache_read_input_tokens"     => 5000,
          "cache_creation_input_tokens" => 0,
          "output_tokens"               => 200
        }
      )
      # 1000 * 1.00 + 5000 * 0.10 + 0 * 1.25 + 200 * 5.00 = 1000 + 500 + 0 + 1000 = 2500 / 1M
      expect(entry[:cost]).to be_within(0.0000001).of(0.0025)
    end

    it "applies cache-write pricing" do
      entry = described_class.record(
        model: "claude-haiku-4-5-20251001",
        usage: { "cache_creation_input_tokens" => 1000, "output_tokens" => 0, "input_tokens" => 0 }
      )
      # 1000 * 1.25 / 1M = 0.00125
      expect(entry[:cost]).to be_within(0.0000001).of(0.00125)
    end

    it "uses default pricing for unknown models" do
      entry = described_class.record(
        model: "claude-mystery-model",
        usage: { "input_tokens" => 1_000_000, "output_tokens" => 0 }
      )
      # default input rate $3 / Mtok = $3.00 for 1M tokens
      expect(entry[:cost]).to be_within(0.0001).of(3.0)
    end

    it "skips silently on nil usage" do
      expect { described_class.record(model: "x", usage: nil) }.not_to raise_error
      expect(described_class.turn_ledger).to be_empty
    end
  end

  describe ".in_subsystem" do
    it "tags records with the surrounding subsystem" do
      described_class.in_subsystem(:belief_materializer) do
        described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 100, "output_tokens" => 10 })
      end
      expect(described_class.turn_ledger.first[:subsystem]).to eq(:belief_materializer)
    end

    it "untagged records fall to :unknown" do
      described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 1, "output_tokens" => 0 })
      expect(described_class.turn_ledger.first[:subsystem]).to eq(:unknown)
    end

    it "stack-based — nested wraps use the innermost tag" do
      described_class.in_subsystem(:outer) do
        described_class.in_subsystem(:inner) do
          described_class.record(model: "x", usage: { "input_tokens" => 1, "output_tokens" => 0 })
        end
        described_class.record(model: "x", usage: { "input_tokens" => 1, "output_tokens" => 0 })
      end
      tags = described_class.turn_ledger.map { |e| e[:subsystem] }
      expect(tags).to eq([ :inner, :outer ])
    end

    it "pops the stack even on raise" do
      expect {
        described_class.in_subsystem(:will_blow_up) { raise "boom" }
      }.to raise_error("boom")
      expect(described_class.current_subsystem).to eq(:unknown)
    end
  end

  describe "turn vs session ledgers" do
    it "reset_turn! clears only the turn ledger" do
      described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 100, "output_tokens" => 10 })
      described_class.reset_turn!
      expect(described_class.turn_ledger).to be_empty
      expect(described_class.session_ledger).not_to be_empty
    end

    it "session_total accumulates across turn resets" do
      described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 1_000_000, "output_tokens" => 0 })
      described_class.reset_turn!
      described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 1_000_000, "output_tokens" => 0 })
      # Each call: 1M * $1/Mtok = $1.00
      expect(described_class.session_total).to be_within(0.0001).of(2.0)
      expect(described_class.turn_total).to be_within(0.0001).of(1.0)
    end
  end

  describe ".turn_breakdown" do
    it "groups by subsystem with summed cost and call count" do
      described_class.in_subsystem(:reasoning_loop) do
        described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 100, "output_tokens" => 50 })
        described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 100, "output_tokens" => 50 })
      end
      described_class.in_subsystem(:narration) do
        described_class.record(model: "claude-haiku-4-5-20251001", usage: { "input_tokens" => 200, "output_tokens" => 100 })
      end

      breakdown = described_class.turn_breakdown
      expect(breakdown[:reasoning_loop][:calls]).to eq(2)
      expect(breakdown[:reasoning_loop][:input]).to eq(200)
      expect(breakdown[:narration][:calls]).to eq(1)
      expect(breakdown[:narration][:output]).to eq(100)
    end
  end
end
