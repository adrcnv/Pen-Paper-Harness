require "rails_helper"

RSpec.describe Harness::Event::BackwardAppender::Hydrator do
  def hydrate(obj)
    described_class.hydrate(llm_output: obj.is_a?(String) ? obj : obj.to_json)
  end

  it "accepts {consistent: true, reasons: []}" do
    out = hydrate({ "consistent" => true, "reasons" => [] })
    expect(out).to eq("consistent" => true, "reasons" => [])
  end

  it "accepts {consistent: false, reasons: [...]}" do
    out = hydrate({ "consistent" => false, "reasons" => [ "X dies in proposed but lives later", "Y is in two places at once" ] })
    expect(out["reasons"]).to eq([ "X dies in proposed but lives later", "Y is in two places at once" ])
  end

  it "rejects non-JSON output" do
    expect { hydrate("not json") }.to raise_error(described_class::InvalidOutput, /not valid JSON/)
  end

  it "rejects non-hash top level" do
    expect { hydrate([].to_json) }.to raise_error(described_class::InvalidOutput, /must be a JSON object/)
  end

  it "rejects non-boolean consistent" do
    expect {
      hydrate({ "consistent" => "yes", "reasons" => [] })
    }.to raise_error(described_class::InvalidOutput, /must be a boolean/)
  end

  it "rejects when reasons is not an array" do
    expect {
      hydrate({ "consistent" => true, "reasons" => "none" })
    }.to raise_error(described_class::InvalidOutput, /must be an array/)
  end

  it "rejects consistent=true with non-empty reasons" do
    expect {
      hydrate({ "consistent" => true, "reasons" => [ "x" ] })
    }.to raise_error(described_class::InvalidOutput, /requires reasons to be empty/)
  end

  it "rejects consistent=false with empty reasons" do
    expect {
      hydrate({ "consistent" => false, "reasons" => [] })
    }.to raise_error(described_class::InvalidOutput, /requires at least one reason/)
  end

  it "rejects empty reason strings" do
    expect {
      hydrate({ "consistent" => false, "reasons" => [ "  " ] })
    }.to raise_error(described_class::InvalidOutput, /must be a non-empty string/)
  end
end
