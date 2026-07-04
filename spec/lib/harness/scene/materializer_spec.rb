require "rails_helper"

RSpec.describe Harness::Scene::Materializer do
  let(:city)      { Location.create!(name: "Saltmere", description: "harbor city") }
  let(:tavern)    { Location.create!(name: "Dockside Inn", description: "dim tavern", parent: city, properties: { "kind" => "tavern" }) }
  let(:warehouse) { Location.create!(name: "Warehouse", description: "crates", parent: city, properties: { "kind" => "warehouse" }) }

  # Fake LLM returns whatever hash/string it's initialized with. Captures prompt for assertions.
  def fake_llm(response)
    captured = []
    client = StubLLM.new { |prompt|
      captured << prompt
      response.is_a?(String) ? response : response.to_json
    }
    client.define_singleton_method(:prompts) { captured }
    client
  end

  describe "when no slots need filling" do
    it "no-ops if already_present >= target_count" do
      Npc.create!(name: "Maren", subrole: "barkeep", location: tavern)
      Npc.create!(name: "Joey",    subrole: "patron",  location: tavern)

      llm = fake_llm({ "reuse" => [], "spawn" => [] })
      out = described_class.new(llm_client: llm).materialize(location: tavern, target_count: 2)

      expect(out).to eq(reused: [], spawned: [])
      expect(llm.prompts).to be_empty  # no LLM call when at-target
    end
  end

  describe "fresh spawn only" do
    it "creates new characters at the requesting location with mechanical names" do
      llm = fake_llm({
        "reuse" => [],
        "spawn" => [
          { "subrole" => "barkeep", "properties" => { "personality" => "stoic" } },
          { "subrole" => "fisher", "properties" => {} }
        ]
      })
      out = described_class.new(llm_client: llm).materialize(location: tavern, target_count: 2)

      expect(out[:reused]).to be_empty
      expect(out[:spawned].size).to eq(2)
      expect(out[:spawned].map(&:location)).to all(eq(tavern))
      # Names come from Harness::Naming — every spawn must have a non-empty
      # name drawn from a culture pool (no nil, no blank, no "Marn"/"Joey").
      expect(out[:spawned].map(&:name)).to all(be_a(String))
      expect(out[:spawned].map(&:name)).to all(satisfy { |n| !n.strip.empty? })
      # Subroles came through; first spawn carries the stoic personality.
      barkeep = out[:spawned].find { |c| c.subrole == "barkeep" }
      expect(barkeep.properties).to include("personality" => "stoic")
    end

    it "respects the slots_to_fill cap" do
      Npc.create!(name: "Existing Barkeep", subrole: "barkeep", location: tavern)
      llm = fake_llm({
        "reuse" => [],
        "spawn" => [
          { "subrole" => "labourer" },
          { "subrole" => "labourer" }
        ]
      })
      out = described_class.new(llm_client: llm).materialize(location: tavern, target_count: 3)
      expect(out[:spawned].size).to eq(2)
    end
  end

  describe "reuse (dormant wake only)" do
    # Reuse is dormant-ONLY now. The candidate pool is dormant historicals at
    # the parent city / sibling sublocations; active residents are never
    # offered (they reach a scene via the transient draws instead). These
    # tests use dormant rows because nothing else can be a candidate.
    it "relocates a dormant historical from the parent city into this sublocation" do
      # A dormant founder lives at the parent city; waking her at the child
      # sublocation moves her here and gives her a subrole.
      marta = Npc.create!(name: "Marta of the Moss", subrole: nil, location: city, properties: { "dormant" => true })

      llm = fake_llm({
        "reuse" => [ { "character_id" => marta.id, "subrole" => "innkeeper", "properties" => { "mood" => "calm" } } ],
        "spawn" => []
      })
      out = described_class.new(llm_client: llm).materialize(location: tavern, target_count: 1)

      expect(out[:reused].size).to eq(1)
      char = out[:reused].first
      expect(char.id).to eq(marta.id)
      expect(char.location).to eq(tavern)
      expect(char.subrole).to eq("innkeeper")
      expect(char.properties).to include("mood" => "calm")
    end

    it "candidate pool includes dormant historicals at the parent city itself (Genesis-tier)" do
      # Critical regression: Genesis materializes dormant Characters at the city
      # tier. Without including the parent, those historicals would be invisible
      # to the materializer at any child sublocation.
      city_dweller = Npc.create!(name: "Aldric the Scout", location: city, properties: { "dormant" => true })
      llm = fake_llm({ "reuse" => [], "spawn" => [] })
      described_class.new(llm_client: llm).materialize(location: tavern, target_count: 1)

      prompt = llm.prompts.first
      expect(prompt).to match(/"character_id"\s*:\s*#{city_dweller.id}/)
      expect(prompt).to match(/"name"\s*:\s*"Aldric the Scout"/)
    end

    it "candidate pool includes dormant historicals at sibling sublocations" do
      sibling_dweller = Npc.create!(name: "Korr", location: warehouse, properties: { "dormant" => true })
      llm = fake_llm({ "reuse" => [], "spawn" => [] })
      described_class.new(llm_client: llm).materialize(location: tavern, target_count: 1)

      prompt = llm.prompts.first
      expect(prompt).to match(/"character_id"\s*:\s*#{sibling_dweller.id}/)
    end

    it "candidate pool excludes characters already at THIS sublocation" do
      already = Npc.create!(name: "Maren", subrole: "barkeep", location: tavern, properties: { "dormant" => true })
      # Sibling-located dormant gives the candidates list non-empty content so
      # we're asserting against a real candidate list, not against an empty
      # array that would trivially pass.
      sibling = Npc.create!(name: "Korr", location: warehouse, properties: { "dormant" => true })

      llm = fake_llm({ "reuse" => [], "spawn" => [] })
      described_class.new(llm_client: llm).materialize(location: tavern, target_count: 3)

      prompt = llm.prompts.first
      candidate_ids_in_prompt = prompt.scan(/"character_id"\s*:\s*(\d+)/).flatten.map(&:to_i)
      expect(candidate_ids_in_prompt).to include(sibling.id)
      expect(candidate_ids_in_prompt).not_to include(already.id)
    end

    it "candidate pool excludes ACTIVE residents (no teleport-and-reskin)" do
      # The dock-worker-became-a-barkeep bug: an active resident of a sibling
      # sublocation must never appear in the reuse menu. Only dormant rows do.
      active_sibling  = Npc.create!(name: "Dushka", subrole: "dock_worker", location: warehouse, properties: { "personality" => "gruff" })
      dormant_sibling = Npc.create!(name: "Old Bram", location: warehouse, properties: { "dormant" => true })

      llm = fake_llm({ "reuse" => [], "spawn" => [] })
      described_class.new(llm_client: llm).materialize(location: tavern, target_count: 2)

      prompt = llm.prompts.first
      candidate_ids_in_prompt = prompt.scan(/"character_id"\s*:\s*(\d+)/).flatten.map(&:to_i)
      expect(candidate_ids_in_prompt).to include(dormant_sibling.id)
      expect(candidate_ids_in_prompt).not_to include(active_sibling.id)
    end

    it "merges new properties into existing properties without blowing away existing" do
      char = Npc.create!(name: "Marta", location: city, properties: { "dormant" => true, "personality" => "weathered", "physical" => "grey-haired" })
      llm = fake_llm({
        "reuse" => [ { "character_id" => char.id, "subrole" => "innkeeper", "properties" => { "mood" => "calm" } } ],
        "spawn" => []
      })
      described_class.new(llm_client: llm).materialize(location: tavern, target_count: 1)

      char.reload
      expect(char.properties).to include("personality" => "weathered", "physical" => "grey-haired", "mood" => "calm")
    end
  end

  describe "mixed wake + spawn" do
    it "creates both and places them at the requesting location" do
      existing = Npc.create!(name: "Korr", location: city, properties: { "dormant" => true })
      llm = fake_llm({
        "reuse" => [ { "character_id" => existing.id, "subrole" => "fisher" } ],
        "spawn" => [ { "subrole" => "barkeep" } ]
      })
      out = described_class.new(llm_client: llm).materialize(location: tavern, target_count: 2)

      expect(out[:reused].map(&:name)).to eq([ "Korr" ])
      expect(out[:spawned].size).to eq(1)
      expect(out[:spawned].first.subrole).to eq("barkeep")
      expect((out[:reused] + out[:spawned]).map(&:location)).to all(eq(tavern))
    end
  end

  describe "no-parent locations" do
    it "scopes presence and candidates to the location itself; runs without a parent" do
      wilderness = Location.create!(name: "Bandit Cave")
      llm = fake_llm({
        "reuse" => [],
        "spawn" => [ { "subrole" => "bandit" } ]
      })
      out = described_class.new(llm_client: llm).materialize(location: wilderness, target_count: 1)
      expect(out[:spawned].size).to eq(1)
      expect(out[:spawned].first.subrole).to eq("bandit")
      expect(out[:spawned].first.location).to eq(wilderness)
    end
  end

  describe "wake (dormant historical)" do
    # Genesis eager-spawns dormant Character rows for every named historical
    # in a backstory cluster. When the player intersects a location where
    # one of those historicals lives, the materializer can pick them as
    # `reuse` — the apply step clears properties.dormant and relocates them
    # into the current sublocation. Dormant rows are the ONLY reuse
    # candidates (preference order: wake-dormant > spawn).
    it "wakes a dormant historical by clearing properties.dormant on reuse" do
      historical = Npc.create!(
        name: "Corren Ashvale",
        subrole: "founder",
        location: city,
        properties: { "dormant" => true }
      )

      llm = fake_llm({
        "reuse" => [ { "character_id" => historical.id, "subrole" => "wanderer", "properties" => { "mood" => "wary" } } ],
        "spawn" => []
      })
      out = described_class.new(llm_client: llm).materialize(location: tavern, target_count: 1)

      expect(out[:reused].size).to eq(1)
      corren = out[:reused].first.reload
      expect(corren.name).to eq("Corren Ashvale")
      expect(corren.location).to eq(tavern)
      expect(corren.subrole).to eq("wanderer")
      expect(corren.properties).to include("mood" => "wary")
      expect(corren.properties).not_to have_key("dormant")
    end

    it "surfaces only dormant candidates in the prompt; active ones are omitted" do
      dormant = Npc.create!(name: "Aelin", location: city, properties: { "dormant" => true })
      active  = Npc.create!(name: "Korr",  location: city, properties: { "personality" => "stoic" })

      llm = fake_llm({ "reuse" => [], "spawn" => [] })
      described_class.new(llm_client: llm).materialize(location: tavern, target_count: 2)

      prompt = llm.prompts.first
      expect(prompt).to match(/"name": "Aelin"/)
      expect(prompt).not_to match(/"name": "Korr"/)
      expect(prompt).to match(/"dormant": true/)
    end
  end

  describe "retry on invalid output" do
    # The eager Hatchery (post-stats-materialization redesign) fires a stats
    # LLM call per spawned character. Route by prompt-content marker so this
    # spec only counts MATERIALIZER attempts, not the orthogonal stats calls.
    STATS_DEFAULT = {
      "level" => 1,
      "strength" => 10, "dexterity" => 10, "constitution" => 10,
      "intelligence" => 10, "wisdom" => 10, "charisma" => 10
    }.to_json.freeze

    DESCRIPTION_DEFAULT = {
      "personality" => "Quiet, watchful; speaks only when spoken to and answers in fewer words than expected.",
      "appearance"  => "Average height, plain dress, hands clean but not soft — the build of someone who has worked but not heavily."
    }.to_json.freeze

    it "re-prompts once when hydrator rejects, accepts on second try" do
      attempt = 0
      client = StubLLM.new { |prompt|
        if prompt.include?("generating a LEVEL and six ability scores")
          STATS_DEFAULT
        elsif prompt.include?("generating a personality and a physical appearance")
          DESCRIPTION_DEFAULT
        else
          attempt += 1
          if attempt == 1
            { "reuse" => [ { "character_id" => 9999, "subrole" => "x" } ], "spawn" => [] }.to_json
          else
            { "reuse" => [], "spawn" => [ { "subrole" => "barkeep" } ] }.to_json
          end
        end
      }

      out = described_class.new(llm_client: client).materialize(location: tavern, target_count: 1)
      expect(out[:spawned].size).to eq(1)
      expect(out[:spawned].first.subrole).to eq("barkeep")
      expect(attempt).to eq(2)
    end

    it "raises after exhausting retries" do
      client = StubLLM.new { |_prompt|
        { "reuse" => [ { "character_id" => 9999, "subrole" => "x" } ], "spawn" => [] }.to_json
      }
      expect {
        described_class.new(llm_client: client, max_retries: 1).materialize(location: tavern, target_count: 1)
      }.to raise_error(Harness::Scene::Materializer::Hydrator::InvalidOutput)
    end
  end

  describe "cache prefix stability" do
    it_behaves_like "stable cache prefix" do
      let(:llm) {
        attempt = 0
        StubLLM.new do |_prompt|
          attempt += 1
          if attempt == 1
            { "reuse" => [ { "character_id" => 9999, "subrole" => "x" } ], "spawn" => [] }.to_json
          else
            { "reuse" => [], "spawn" => [] }.to_json
          end
        end
      }

      let(:exercise) {
        -> {
          described_class.new(llm_client: llm, max_retries: 1).materialize(location: tavern,    target_count: 1)
          described_class.new(llm_client: llm).materialize(location: warehouse, target_count: 2)
        }
      }
    end
  end
end
