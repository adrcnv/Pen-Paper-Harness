require "rails_helper"

RSpec.describe Harness::Scene::Materializer::Hydrator do
  let(:candidate_ids) { [ 17, 23 ] }
  let(:present_names) { %w[Maren] }
  let(:slots_to_fill) { 3 }

  def hydrate(obj)
    described_class.hydrate(
      llm_output:    obj.is_a?(String) ? obj : obj.to_json,
      candidate_ids: candidate_ids,
      present_names: present_names,
      slots_to_fill: slots_to_fill
    )
  end

  describe "happy path" do
    it "returns normalized reuse and spawn entries" do
      out = hydrate(
        "reuse" => [ { "character_id" => 17, "subrole" => "smuggler", "properties" => { "personality" => "cagey" } } ],
        "spawn" => [ { "subrole" => "drunk_patron", "properties" => {} } ]
      )
      expect(out["reuse"].first).to include("character_id" => 17, "subrole" => "smuggler")
      expect(out["spawn"].first).to include("subrole" => "drunk_patron")
      # Post-Phase-3: names are mechanical; hydrator does not emit a name field.
      expect(out["spawn"].first).not_to have_key("name")
    end

    it "accepts empty reuse and spawn arrays" do
      out = hydrate("reuse" => [], "spawn" => [])
      expect(out["reuse"]).to eq([])
      expect(out["spawn"]).to eq([])
    end

    it "defaults missing properties to empty hash" do
      out = hydrate("reuse" => [ { "character_id" => 17, "subrole" => "smuggler" } ], "spawn" => [])
      expect(out["reuse"].first["properties"]).to eq({})
    end
  end

  describe "top-level shape" do
    it "rejects non-object output" do
      expect { hydrate([ 1, 2, 3 ].to_json) }.to raise_error(described_class::InvalidOutput, /must be a JSON object/)
    end

    it "rejects missing reuse array" do
      expect { hydrate("spawn" => []) }.to raise_error(described_class::InvalidOutput, /reuse/)
    end

    it "rejects missing spawn array" do
      expect { hydrate("reuse" => []) }.to raise_error(described_class::InvalidOutput, /spawn/)
    end
  end

  describe "reuse validation" do
    it "rejects character_id not in CANDIDATES" do
      expect {
        hydrate("reuse" => [ { "character_id" => 999, "subrole" => "x" } ], "spawn" => [])
      }.to raise_error(described_class::InvalidOutput, /not in CANDIDATES/)
    end

    it "rejects non-integer character_id" do
      expect {
        hydrate("reuse" => [ { "character_id" => "17", "subrole" => "x" } ], "spawn" => [])
      }.to raise_error(described_class::InvalidOutput, /character_id must be an integer/)
    end

    it "rejects duplicate character_id within reuse" do
      expect {
        hydrate(
          "reuse" => [
            { "character_id" => 17, "subrole" => "x" },
            { "character_id" => 17, "subrole" => "y" }
          ],
          "spawn" => []
        )
      }.to raise_error(described_class::InvalidOutput, /twice in reuse/)
    end

    it "rejects missing subrole" do
      expect {
        hydrate("reuse" => [ { "character_id" => 17 } ], "spawn" => [])
      }.to raise_error(described_class::InvalidOutput, /subrole must be a non-empty string/)
    end

    it "rejects non-hash properties" do
      expect {
        hydrate("reuse" => [ { "character_id" => 17, "subrole" => "x", "properties" => "bad" } ], "spawn" => [])
      }.to raise_error(described_class::InvalidOutput, /properties must be an object/)
    end
  end

  describe "spawn validation" do
    it "silently drops any name field the LLM tries to supply (engine names are mechanical)" do
      out = hydrate("reuse" => [], "spawn" => [ { "name" => "Elara", "subrole" => "barkeep" } ])
      expect(out["spawn"].first).not_to have_key("name")
    end

    it "still requires a subrole" do
      expect {
        hydrate("reuse" => [], "spawn" => [ { "properties" => {} } ])
      }.to raise_error(described_class::InvalidOutput, /subrole must be a non-empty string/)
    end
  end

  describe "budget" do
    it "rejects total reuse+spawn exceeding SLOTS_TO_FILL" do
      expect {
        hydrate(
          "reuse" => [ { "character_id" => 17, "subrole" => "x" }, { "character_id" => 23, "subrole" => "x" } ],
          "spawn" => [ { "subrole" => "x" }, { "subrole" => "x" } ]
          # total 4, slots 3
        )
      }.to raise_error(described_class::InvalidOutput, /exceeds SLOTS_TO_FILL/)
    end

    it "accepts total equal to SLOTS_TO_FILL" do
      expect {
        hydrate(
          "reuse" => [ { "character_id" => 17, "subrole" => "x" } ],
          "spawn" => [ { "subrole" => "x" }, { "subrole" => "x" } ]
        )
      }.not_to raise_error
    end

    it "accepts fewer than SLOTS_TO_FILL (quiet scene)" do
      expect {
        hydrate("reuse" => [], "spawn" => [ { "subrole" => "x" } ])
      }.not_to raise_error
    end
  end
end
