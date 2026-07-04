require "rails_helper"

RSpec.describe Harness::Knowledge::Gate do
  let(:fact_class) { Struct.new(:id, :content) }
  let(:facts) do
    [ fact_class.new(1, "The salt tithe was repealed last winter."),
      fact_class.new(2, "The smithy closes at dusk.") ]
  end

  def gate(response, topic: "is there still a salt tithe?", facts: self.facts)
    llm = StubLLM.new { |_p| response.is_a?(String) ? response : response.to_json }
    described_class.run(llm: llm, topic: topic, facts: facts)
  end

  it "returns only the facts whose ids the gate marks relevant" do
    out = gate({ "relevant" => [ 1 ] })
    expect(out.map(&:id)).to eq([ 1 ])
  end

  it "returns [] when the gate says none are relevant" do
    expect(gate({ "relevant" => [] })).to eq([])
  end

  it "ignores ids not in the candidate set" do
    out = gate({ "relevant" => [ 1, 999 ] })
    expect(out.map(&:id)).to eq([ 1 ])
  end

  it "returns [] and makes NO llm call when there are no facts" do
    llm = StubLLM.new { |_p| raise "should not be called" }
    expect(described_class.run(llm: llm, topic: "x", facts: [])).to eq([])
  end

  it "fails safe to [] on unparseable output (recall nothing, never leak noise)" do
    expect(gate("not json at all")).to eq([])
  end
end
