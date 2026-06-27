require "rails_helper"

RSpec.describe Harness::Description::Hydrator do
  def hydrate(obj)
    described_class.hydrate(llm_output: obj.is_a?(String) ? obj : obj.to_json)
  end

  def good
    {
      "personality" => "Steady-handed and slow to anger; speaks plainly to those he respects.",
      "appearance"  => "Broad-shouldered, with weathered hands and a faded scar along his left jaw."
    }
  end

  it "accepts well-formed personality + appearance" do
    out = hydrate(good)
    expect(out[:personality]).to start_with("Steady-handed")
    expect(out[:appearance]).to include("scar")
  end

  it "strips whitespace" do
    out = hydrate("personality" => "  " + good["personality"] + "  ", "appearance" => good["appearance"])
    expect(out[:personality]).to eq(good["personality"])
  end

  it "rejects missing personality" do
    expect { hydrate(good.except("personality")) }
      .to raise_error(described_class::InvalidOutput, /missing field: personality/)
  end

  it "rejects missing appearance" do
    expect { hydrate(good.except("appearance")) }
      .to raise_error(described_class::InvalidOutput, /missing field: appearance/)
  end

  it "rejects too-short fields" do
    expect { hydrate("personality" => "short", "appearance" => good["appearance"]) }
      .to raise_error(described_class::InvalidOutput, /personality length=5 must be between/)
  end

  it "accepts a compact trait-list personality below the old 30-char prose floor" do
    out = hydrate("personality" => "wary, terse, dry", "appearance" => good["appearance"])
    expect(out[:personality]).to eq("wary, terse, dry")
  end

  it "still holds appearance to the prose floor (30)" do
    expect { hydrate("personality" => "wary, terse, dry", "appearance" => "tall, lean") }
      .to raise_error(described_class::InvalidOutput, /appearance length=10 must be between 30 and 400/)
  end

  it "rejects a personality over its 120 ceiling even when under the prose 400" do
    long_traits = "wary, " * 30 # ~180 chars
    expect { hydrate("personality" => long_traits, "appearance" => good["appearance"]) }
      .to raise_error(described_class::InvalidOutput, /personality length=\d+ must be between 10 and 120/)
  end

  it "rejects too-long fields" do
    long = "a" * 500
    expect { hydrate("personality" => long, "appearance" => good["appearance"]) }
      .to raise_error(described_class::InvalidOutput, /personality length=500 must be between/)
  end

  it "rejects non-string field values" do
    expect { hydrate("personality" => 42, "appearance" => good["appearance"]) }
      .to raise_error(described_class::InvalidOutput, /personality must be a string/)
  end

  it "rejects non-hash top-level" do
    expect { hydrate([ 1, 2 ].to_json) }.to raise_error(described_class::InvalidOutput, /JSON object/)
  end

  it "rejects malformed JSON" do
    expect { hydrate("not json") }.to raise_error(described_class::InvalidOutput, /not valid JSON/)
  end
end
