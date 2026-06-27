require "rails_helper"

RSpec.describe Harness::Render do
  K = Harness::Render::KNOWN_COLOR
  Q = Harness::Render::QUOTE_COLOR
  R = Harness::Render::RESET

  describe ".narration" do
    it "returns the text verbatim when color is off" do
      out = described_class.narration("Maren nods at Harek.", known_names: ["Maren"], color: false)
      expect(out).to eq("Maren nods at Harek.")
    end

    it "highlights a known name in the known colour" do
      out = described_class.narration("Maren pours a drink.", known_names: ["Maren"], color: true)
      expect(out).to eq("#{K}Maren#{R} pours a drink.")
    end

    it "does NOT highlight an unknown capitalised name (no yellow concept)" do
      out = described_class.narration("Maren mentions Harek.", known_names: ["Maren"], color: true)
      expect(out).to eq("#{K}Maren#{R} mentions Harek.")
    end

    it "colours a known name through its possessive 's (straight and curly)" do
      out1 = described_class.narration("Hilde's ledger sits open.", known_names: ["Hilde"], color: true)
      expect(out1).to eq("#{K}Hilde's#{R} ledger sits open.")
      out2 = described_class.narration("Hilde’s ledger sits open.", known_names: ["Hilde"], color: true)
      expect(out2).to eq("#{K}Hilde’s#{R} ledger sits open.")
    end

    it "prefers a multi-word known name over the bare words inside it" do
      out = described_class.narration(
        "You reach Blackwood Relay at dusk.",
        known_names: ["Blackwood Relay"], color: true
      )
      expect(out).to eq("You reach #{K}Blackwood Relay#{R} at dusk.")
    end

    it "matches known names case-insensitively but preserves the printed casing" do
      out = described_class.narration("the tavern at MAREN's place", known_names: ["Maren"], color: true)
      expect(out).to include("#{K}MAREN's#{R}")
    end

    it "leaves text with no known names untouched" do
      out = described_class.narration("the door creaks open slowly", known_names: ["Maren"], color: true)
      expect(out).to eq("the door creaks open slowly")
    end

    it "dims a bracket line and colours the outcome by tier" do
      line = "[force the door — Strength 14 vs 20: failure, decisive]"
      out = described_class.narration(line, known_names: [], color: true)
      expect(out).to start_with(Harness::Render::DIM)
      expect(out).to end_with(R)
      expect(out).to include("#{Harness::Render::OUTCOME_COLOR['failure']}failure#{R}")
    end

    it "does not paint a known name inside a bracket line" do
      line = "[Heavy Strike — Strength 17 vs 12: success, clear]"
      out = described_class.narration(line, known_names: ["Strength"], color: true)
      expect(out).not_to include("#{K}Strength")
    end
  end

  describe "quoted speech" do
    it "colors straight-quoted text green" do
      out = described_class.narration(%(He said "good morning" softly.), known_names: [], color: true)
      expect(out).to include("#{Q}\"good morning\"#{R}")
    end

    it "colors curly-quoted text green (the model uses both)" do
      out = described_class.narration("He said “good morning” softly.", known_names: [], color: true)
      expect(out).to include("#{Q}“good morning”#{R}")
    end

    it "still pops a known name inside a quote, resuming the quote colour" do
      out = described_class.narration(%(She said "find Maren at the docks"), known_names: ["Maren"], color: true)
      expect(out).to include("#{K}Maren#{Q}")
      expect(out).to start_with(%(She said #{Q}"find ))
    end
  end

  describe ".rule" do
    it "is plain when color is off and carries the centre ornament" do
      expect(described_class.rule(width: 21, color: false)).to eq("#{'─' * 9}◆#{'─' * 9}")
    end

    it "wraps in the dim sequence when color is on" do
      r = described_class.rule(width: 21, color: true)
      expect(r).to start_with(Harness::Render::RULE_COLOR)
      expect(r).to end_with(Harness::Render::RESET)
    end
  end
end
