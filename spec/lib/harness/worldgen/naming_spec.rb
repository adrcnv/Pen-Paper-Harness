require "rails_helper"

RSpec.describe Harness::Worldgen::Naming do
  let(:map) {
    Harness::Worldgen::Map.new(
      seed: 1, size: 100,
      cities: [
        Harness::Worldgen::City.new(id: 0, x: 10.0, y: 10.0, biome: "lowland", kingdom_id: 0),
        Harness::Worldgen::City.new(id: 1, x: 12.0, y: 11.0, biome: "highland", kingdom_id: 0),
        Harness::Worldgen::City.new(id: 2, x: 80.0, y: 80.0, biome: "lowland", kingdom_id: 1),
      ],
      kingdoms: [
        Harness::Worldgen::Kingdom.new(id: 0, anchor_city_id: 0),
        Harness::Worldgen::Kingdom.new(id: 1, anchor_city_id: 2),
      ]
    )
  }

  def fake_response_for(kingdom_name:, city_names:)
    JSON.generate(
      "kingdom" => {
        "name"        => kingdom_name,
        "description" => "A windswept land where the rocks remember every footfall and the wind never quite forgets the sea."
      },
      "cities" => city_names.transform_values do |name|
        { "name" => name, "description" => "A modest place of #{name.downcase} stone, smelling of woodsmoke and old salt all year round." }
      end
    )
  end

  it "names every kingdom and every city via one LLM call per kingdom" do
    responses = [
      fake_response_for(kingdom_name: "Karhast", city_names: { "0" => "Stormcrag", "1" => "Holgren" }),
      fake_response_for(kingdom_name: "Velen",   city_names: { "2" => "Mistmere" }),
    ]
    fake_llm = double("llm")
    expect(fake_llm).to receive(:complete).twice.and_return(*responses)

    described_class.name!(map: map, llm: fake_llm)

    expect(map.kingdoms[0].name).to eq("Karhast")
    expect(map.kingdoms[1].name).to eq("Velen")
    expect(map.cities[0].name).to eq("Stormcrag")
    expect(map.cities[1].name).to eq("Holgren")
    expect(map.cities[2].name).to eq("Mistmere")
    expect(map.cities.map(&:description)).to all(be_present)
    expect(map.kingdoms.map(&:description)).to all(be_present)
  end

  it "passes a separate system + user (so adapter caching applies)" do
    captured = []
    responses = [
      fake_response_for(kingdom_name: "Karhast", city_names: { "0" => "Stormcrag", "1" => "Holgren" }),
      fake_response_for(kingdom_name: "Velen",   city_names: { "2" => "Mistmere" })
    ]
    fake_llm = double("llm")
    allow(fake_llm).to receive(:complete) do |system:, user:|
      captured << { system: system, user: user }
      responses[captured.size - 1]
    end

    described_class.name!(map: map, llm: fake_llm)

    expect(captured.size).to eq(2)
    # System message is the same across calls (the cacheable head).
    expect(captured.first[:system]).to eq(captured.last[:system])
    # User message differs (per-kingdom INPUT).
    expect(captured.first[:user]).not_to eq(captured.last[:user])
  end

  it "retries on hydrator failure and eventually raises" do
    fake_llm = double("llm")
    expect(fake_llm).to receive(:complete).twice.and_return("not-json")
    expect {
      described_class.name!(map: map, llm: fake_llm, logger: nil)
    }.to raise_error(Harness::Worldgen::Naming::Hydrator::InvalidOutput)
  end

  it "succeeds on retry if first attempt is malformed" do
    fake_llm = double("llm")
    bad_response  = "not-json"
    good_response = fake_response_for(kingdom_name: "Karhast", city_names: { "0" => "Stormcrag", "1" => "Holgren" })
    expect(fake_llm).to receive(:complete).and_return(bad_response, good_response, fake_response_for(kingdom_name: "Velen", city_names: { "2" => "Mistmere" }))
    described_class.name!(map: map, llm: fake_llm, logger: nil)
    expect(map.kingdoms[0].name).to eq("Karhast")
    expect(map.kingdoms[1].name).to eq("Velen")
  end
end
