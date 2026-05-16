require "rails_helper"

RSpec.describe Harness::Worldgen::Naming::Hydrator do
  def valid_output(kingdom_name: "Karhast", cities:)
    {
      "kingdom" => {
        "name"        => kingdom_name,
        "description" => "A windswept realm where the wind never forgets the sea and every stone remembers something."
      },
      "cities" => cities.to_h { |id, name|
        [ id.to_s, {
          "name"        => name,
          "description" => "A small place near the coast, smelling of tar and salt and old fishing boats hauled up the rocks."
        } ]
      }
    }
  end

  describe ".hydrate" do
    it "returns the structured payload for a valid response" do
      raw = JSON.generate(valid_output(cities: { 0 => "Stormcrag", 1 => "Holgren" }))
      result = described_class.hydrate(llm_output: raw, member_ids: [ 0, 1 ])
      expect(result[:kingdom][:name]).to eq("Karhast")
      expect(result[:cities][0][:name]).to eq("Stormcrag")
      expect(result[:cities][1][:name]).to eq("Holgren")
    end

    it "strips markdown fences from the output (the same fence bug the other hydrators handle)" do
      json = JSON.pretty_generate(valid_output(cities: { 0 => "Stormcrag" }))
      raw  = "```json\n#{json}\n```"
      result = described_class.hydrate(llm_output: raw, member_ids: [ 0 ])
      expect(result[:kingdom][:name]).to eq("Karhast")
    end

    it "rejects when a member city is missing from output" do
      raw = JSON.generate(valid_output(cities: { 0 => "Stormcrag" }))
      expect {
        described_class.hydrate(llm_output: raw, member_ids: [ 0, 1 ])
      }.to raise_error(described_class::InvalidOutput, /missing entries for city ids: 1/)
    end

    it "rejects when extra cities sneak in" do
      raw = JSON.generate(valid_output(cities: { 0 => "Stormcrag", 99 => "Ghost" }))
      expect {
        described_class.hydrate(llm_output: raw, member_ids: [ 0 ])
      }.to raise_error(described_class::InvalidOutput, /unexpected entries for city ids: 99/)
    end

    it "rejects when names are too short" do
      data = valid_output(cities: { 0 => "X" })
      raw = JSON.generate(data)
      expect {
        described_class.hydrate(llm_output: raw, member_ids: [ 0 ])
      }.to raise_error(described_class::InvalidOutput, /too short/)
    end

    it "rejects when descriptions are below the minimum" do
      data = valid_output(cities: { 0 => "Stormcrag" })
      data["cities"]["0"]["description"] = "tiny."
      raw = JSON.generate(data)
      expect {
        described_class.hydrate(llm_output: raw, member_ids: [ 0 ])
      }.to raise_error(described_class::InvalidOutput, /too short/)
    end

    it "rejects malformed JSON" do
      expect {
        described_class.hydrate(llm_output: "definitely not json {", member_ids: [ 0 ])
      }.to raise_error(described_class::InvalidOutput, /not valid JSON/)
    end

    it "rejects missing top-level keys" do
      raw = JSON.generate("kingdom" => { "name" => "X", "description" => "y" * 50 })
      expect {
        described_class.hydrate(llm_output: raw, member_ids: [ 0 ])
      }.to raise_error(described_class::InvalidOutput, /cities/)
    end
  end
end
