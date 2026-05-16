require "rails_helper"

RSpec.describe Harness::Stats::Hydrator do
  def hydrate(obj)
    described_class.hydrate(llm_output: obj.is_a?(String) ? obj : obj.to_json)
  end

  def good_stats(level: 1, character_class: "commoner", **overrides)
    {
      "level"           => level,
      "character_class" => character_class,
      "strength"        => 12,
      "dexterity"       => 10,
      "constitution"    => 14,
      "intelligence"    => 9,
      "wisdom"          => 11,
      "charisma"        => 13
    }.merge(overrides)
  end

  it "accepts a well-formed object with level + class + 6 stats" do
    out = hydrate(good_stats(level: 3, character_class: "fighter"))
    expect(out[:level]).to eq(3)
    expect(out[:character_class]).to eq("fighter")
    expect(out[:strength]).to eq(12)
    expect(out[:wisdom]).to eq(11)
  end

  it "rejects missing character_class" do
    expect { hydrate(good_stats.except("character_class")) }
      .to raise_error(described_class::InvalidOutput, /missing field: character_class/)
  end

  it "rejects unknown character_class" do
    expect { hydrate(good_stats(character_class: "warlock")) }
      .to raise_error(described_class::InvalidOutput, /character_class.*must be one of/)
  end

  it "rejects non-hash top level" do
    expect { hydrate([ 1, 2 ].to_json) }.to raise_error(described_class::InvalidOutput, /JSON object/)
  end

  it "rejects missing level" do
    expect {
      hydrate(good_stats.except("level"))
    }.to raise_error(described_class::InvalidOutput, /missing field: level/)
  end

  it "rejects level < 1" do
    expect { hydrate(good_stats(level: 0)) }.to raise_error(described_class::InvalidOutput, /level=0 must be >= 1/)
  end

  it "rejects level above sanity ceiling (likely hallucination)" do
    expect { hydrate(good_stats(level: 9999)) }.to raise_error(described_class::InvalidOutput, /sanity ceiling/)
  end

  it "accepts very high but plausible levels (no hard cap below ceiling)" do
    out = hydrate(good_stats(level: 18))
    expect(out[:level]).to eq(18)
  end

  it "rejects missing stat keys" do
    expect {
      hydrate(good_stats.except("intelligence"))
    }.to raise_error(described_class::InvalidOutput, /missing stat/)
  end

  it "rejects non-integer stat values" do
    expect { hydrate(good_stats("strength" => "ten")) }
      .to raise_error(described_class::InvalidOutput, /must be integer/)
  end

  it "rejects stat values above 18" do
    expect { hydrate(good_stats("strength" => 25)) }
      .to raise_error(described_class::InvalidOutput, /out of range/)
  end

  it "rejects stat values below 3" do
    expect { hydrate(good_stats("wisdom" => 1)) }
      .to raise_error(described_class::InvalidOutput, /out of range/)
  end

  it "aggregates multiple errors" do
    bad = { "level" => 1, "strength" => "x", "dexterity" => 999 }
    begin
      hydrate(bad)
    rescue described_class::InvalidOutput => e
      expect(e.errors.size).to be >= 2
      expect(e.errors.any? { |m| m.include?("must be integer") }).to be(true)
      expect(e.errors.any? { |m| m.include?("missing stat") }).to be(true)
    end
  end
end
