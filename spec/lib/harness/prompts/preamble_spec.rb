require "rails_helper"

RSpec.describe Harness::Prompts::Preamble do
  describe ".render" do
    it "substitutes every vocabulary placeholder" do
      text = <<~TXT
        scopes: {{SCOPES}}
        kingdom subroles: {{KINGDOM_SUBROLES}}
        non-kingdom subroles: {{NON_KINGDOM_SUBROLES}}
        terrains: {{TERRAINS}}
        kingdom-only kinds: {{KINGDOM_ONLY_KINDS}}
      TXT

      out = described_class.render(text)

      expect(out).to include(Event::ALLOWED_SCOPES.join(", "))
      expect(out).to include(Faction::KINGDOM_SUBROLES.join(" | "))
      expect(out).to include(Faction::NON_KINGDOM_SUBROLES.join(", "))
      expect(out).to include(Location::ALLOWED_TERRAINS.join(" | "))
      expect(out).to include(Location::KINGDOM_ONLY_KINDS.join(", "))

      expect(out).not_to include("{{")
    end

    it "leaves unknown placeholders untouched" do
      expect(described_class.render("a {{UNKNOWN}} b")).to eq("a {{UNKNOWN}} b")
    end

    it "is a no-op on text without placeholders" do
      expect(described_class.render("plain text")).to eq("plain text")
    end
  end

  describe ".load" do
    it "reads the given path and expands vocabulary" do
      tmp = Tempfile.new([ "preamble", ".txt" ])
      tmp.write("scope must be one of: {{SCOPES}}")
      tmp.close

      begin
        out = described_class.load(tmp.path)
        expect(out).to include(Event::ALLOWED_SCOPES.join(", "))
      ensure
        tmp.unlink
      end
    end
  end

  describe "integration with live preamble files" do
    it "expands every placeholder referenced in any real preamble" do
      prompt_files = Dir.glob(Rails.root.join("lib/harness/prompts/*.txt"))
      expect(prompt_files).not_to be_empty

      prompt_files.each do |path|
        rendered = described_class.load(path)
        expect(rendered).not_to include("{{"), "unexpanded placeholder in #{File.basename(path)}"
      end
    end
  end
end
