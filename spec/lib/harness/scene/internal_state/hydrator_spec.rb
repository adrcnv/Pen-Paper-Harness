require "rails_helper"

RSpec.describe Harness::Scene::InternalState::Hydrator do
  let(:expected) { [ "Maren", "Korr" ] }

  def hydrate(obj)
    described_class.hydrate(
      llm_output:     obj.is_a?(String) ? obj : obj.to_json,
      expected_names: expected
    )
  end

  it "accepts well-formed output for all expected characters" do
    out = hydrate({
      "internal_states" => {
        "Maren" => "Maren is short with customers — his back aches and the delivery is late.",
        "Korr"    => "Korr is bored and nursing the same drink he ordered an hour ago."
      }
    })
    expect(out.internal_states["Maren"]).to match(/back aches/)
    expect(out.internal_states["Korr"]).to match(/bored/)
    expect(out.extras).to eq([])
  end

  it "rejects non-JSON output" do
    expect { hydrate("not json") }.to raise_error(described_class::InvalidOutput, /not valid JSON/)
  end

  it "rejects non-hash top level" do
    expect { hydrate([].to_json) }.to raise_error(described_class::InvalidOutput, /must be a JSON object/)
  end

  it "rejects when internal_states is missing or wrong shape" do
    expect { hydrate({ "other" => {} }) }.to raise_error(described_class::InvalidOutput, /must be an object/)
    expect { hydrate({ "internal_states" => [] }) }.to raise_error(described_class::InvalidOutput, /must be an object/)
  end

  it "rejects when an expected character is missing" do
    expect {
      hydrate({ "internal_states" => { "Maren" => "long enough prose line about Maren" } })
    }.to raise_error(described_class::InvalidOutput, /missing entries.*Korr/)
  end

  it "rejects when extra characters appear" do
    expect {
      hydrate({
        "internal_states" => {
          "Maren" => "long enough prose line about Maren here",
          "Korr"    => "long enough prose line about Korr too here",
          "Stranger" => "this person was not asked about and shouldnt be here"
        }
      })
    }.to raise_error(described_class::InvalidOutput, /unexpected entries.*Stranger/)
  end

  it "rejects an empty / too-short prose line" do
    expect {
      hydrate({
        "internal_states" => {
          "Maren" => "",
          "Korr"    => "long enough prose line"
        }
      })
    }.to raise_error(described_class::InvalidOutput, /Maren.*non-empty/)

    expect {
      hydrate({
        "internal_states" => {
          "Maren" => "short",
          "Korr"    => "long enough prose line for korr"
        }
      })
    }.to raise_error(described_class::InvalidOutput, /Maren.*too short/)
  end

  it "rejects a too-long prose line" do
    too_long = "x" * (described_class::MAX_LEN + 1)
    expect {
      hydrate({
        "internal_states" => {
          "Maren" => too_long,
          "Korr"    => "long enough prose line for korr"
        }
      })
    }.to raise_error(described_class::InvalidOutput, /too long/)
  end

  it "rejects a non-string value" do
    expect {
      hydrate({
        "internal_states" => {
          "Maren" => 42,
          "Korr"    => "long enough prose line for korr"
        }
      })
    }.to raise_error(described_class::InvalidOutput, /must be a string/)
  end

  it "trims whitespace before length checks" do
    out = hydrate({
      "internal_states" => {
        "Maren" => "   Maren is in a perfectly fine mood today.   ",
        "Korr"    => "long enough prose line for korr"
      }
    })
    expect(out.internal_states["Maren"]).to eq("Maren is in a perfectly fine mood today.")
  end

  describe "extras" do
    it "returns extras when present and well-formed" do
      out = hydrate({
        "internal_states" => {
          "Maren" => "Maren is short with customers — his back aches and the delivery is late.",
          "Korr"    => "Korr is bored and nursing the same drink he ordered an hour ago."
        },
        "extras" => [
          "an old fisherman at the corner table nursing a beer for an hour",
          "a young courier woman finishing a meal, satchel still slung"
        ]
      })
      expect(out.extras.size).to eq(2)
      expect(out.extras.first).to match(/fisherman/)
    end

    it "treats omitted extras as []" do
      out = hydrate({
        "internal_states" => {
          "Maren" => "Maren is in a plausible mood here today.",
          "Korr"    => "Korr is in a plausible mood here today."
        }
      })
      expect(out.extras).to eq([])
    end

    it "silently caps extras at MAX_EXTRAS=4" do
      out = hydrate({
        "internal_states" => {
          "Maren" => "Maren is in a plausible mood here today.",
          "Korr"    => "Korr is in a plausible mood here today."
        },
        "extras" => [
          "an old fisherman at the corner table nursing a single beer",
          "a young woman knitting by the warmth of the small fire",
          "two men playing dice in the back, low voices",
          "a courier woman finishing a meal, satchel slung",
          "this fifth extra should be silently dropped past the cap"
        ]
      })
      expect(out.extras.size).to eq(4)
    end

    it "rejects non-array extras" do
      expect {
        hydrate({
          "internal_states" => {
            "Maren" => "Maren is in a plausible mood here today.",
            "Korr"    => "Korr is in a plausible mood here today."
          },
          "extras" => "not an array"
        })
      }.to raise_error(described_class::InvalidOutput, /must be an array/)
    end

    it "rejects too-short extras" do
      expect {
        hydrate({
          "internal_states" => {
            "Maren" => "Maren is in a plausible mood here today.",
            "Korr"    => "Korr is in a plausible mood here today."
          },
          "extras" => [ "tiny" ]
        })
      }.to raise_error(described_class::InvalidOutput, /too short/)
    end

    it "rejects non-string extras" do
      expect {
        hydrate({
          "internal_states" => {
            "Maren" => "Maren is in a plausible mood here today.",
            "Korr"    => "Korr is in a plausible mood here today."
          },
          "extras" => [ 42 ]
        })
      }.to raise_error(described_class::InvalidOutput, /must be a string/)
    end
  end

  describe "agenda" do
    def with_agenda(agenda)
      hydrate({
        "internal_states" => {
          "Maren" => "Maren is in a plausible mood here today.",
          "Korr"    => "Korr is in a plausible mood here today."
        },
        "agenda" => agenda
      })
    end

    it "parses a well-formed agenda into an Agenda struct" do
      out = with_agenda(
        "character_name" => "Maren",
        "text"           => "wants to ask the player about the docks; her brother went missing last week and the player just walked in"
      )
      expect(out.agenda).to be_a(described_class::Agenda)
      expect(out.agenda.character_name).to eq("Maren")
      expect(out.agenda.text).to match(/docks/)
    end

    it "treats omitted agenda as nil (most scenes have no agenda)" do
      out = hydrate({
        "internal_states" => {
          "Maren" => "Maren is in a plausible mood here today.",
          "Korr"    => "Korr is in a plausible mood here today."
        }
      })
      expect(out.agenda).to be_nil
    end

    it "treats explicit nil agenda as nil" do
      out = hydrate({
        "internal_states" => {
          "Maren" => "Maren is in a plausible mood here today.",
          "Korr"    => "Korr is in a plausible mood here today."
        },
        "agenda" => nil
      })
      expect(out.agenda).to be_nil
    end

    it "rejects when agenda is not a hash" do
      expect {
        with_agenda("just a string")
      }.to raise_error(described_class::InvalidOutput, /must be an object/)
    end

    it "rejects when agenda character_name is not in INPUT.characters" do
      expect {
        with_agenda(
          "character_name" => "Stranger",
          "text"           => "this person isn't expected to be here in INPUT but the model invented them anyway"
        )
      }.to raise_error(described_class::InvalidOutput, /not in INPUT\.characters/)
    end

    it "rejects when character_name is missing or non-string" do
      expect {
        with_agenda("text" => "wants to ask the player about the docks; her brother went missing last week")
      }.to raise_error(described_class::InvalidOutput, /character_name must be a string/)
    end

    it "rejects when text is missing or non-string" do
      expect {
        with_agenda("character_name" => "Maren")
      }.to raise_error(described_class::InvalidOutput, /text must be a string/)
    end

    it "rejects too-short text" do
      expect {
        with_agenda("character_name" => "Maren", "text" => "too short")
      }.to raise_error(described_class::InvalidOutput, /text is too short/)
    end

    it "rejects too-long text" do
      too_long = "x" * (described_class::AGENDA_MAX_LEN + 1)
      expect {
        with_agenda("character_name" => "Maren", "text" => too_long)
      }.to raise_error(described_class::InvalidOutput, /text is too long/)
    end
  end
end
