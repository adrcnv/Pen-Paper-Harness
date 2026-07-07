require "rails_helper"

RSpec.describe Harness::Character::Hatchery do
  let(:city) { Location.create!(name: "Saltmere") }
  let(:logger) { Logger.new(IO::NULL) }

  def good_stats(level: 1, character_class: "commoner")
    {
      "level" => level, "character_class" => character_class,
      "strength" => 12, "dexterity" => 11, "constitution" => 13,
      "intelligence" => 9, "wisdom" => 10, "charisma" => 12
    }.to_json
  end

  def good_description
    {
      "personality" => "Steady-handed and slow to anger; speaks plainly to those he respects.",
      "appearance"  => "Broad-shouldered, with weathered hands and a faded scar along his left jaw."
    }.to_json
  end

  # Hatchery now fires TWO LLM calls per spawn: stats first, description
  # second. Route by content marker so tests can supply both without
  # depending on call sequence.
  def llm_returning(stats: nil, description: nil)
    StubLLM.new { |prompt|
      if prompt.include?("generating a LEVEL and six ability scores")
        stats || good_stats
      elsif prompt.include?("generating a personality and a physical appearance")
        description || good_description
      else
        raise "unexpected prompt routed to llm_returning: #{prompt.slice(0, 80)}"
      end
    }
  end

  describe ".spawn" do
    it "creates a fresh Npc with stats + level materialized" do
      llm = llm_returning(stats: good_stats(level: 3))

      char = described_class.spawn(
        llm_grunt: llm,
        name:      "Marek",
        subrole:   "captain",
        location:  city
      )

      expect(char).to be_persisted
      expect(char.name).to eq("Marek")
      expect(char.level).to eq(3)
      expect(char.strength).to eq(12)
      expect(char.charisma).to eq(12)
    end

    it "falls back to defaults when llm_grunt is nil" do
      char = described_class.spawn(
        llm_grunt: nil,
        name:      "Patron",
        subrole:   "drunk",
        location:  city
      )

      expect(char.level).to eq(Character::DEFAULT_LEVEL)
      expect(char.strength).to eq(Character::DEFAULT_STAT_VALUE)
      expect(char.charisma).to eq(Character::DEFAULT_STAT_VALUE)
    end

    it "falls back to defaults gracefully when stats materializer raises (no description follow-up)" do
      llm = StubLLM.new { |_p| "not json" }  # stats hydrator rejects, retries exhaust

      char = described_class.spawn(
        llm_grunt: llm,
        name:      "Patron",
        subrole:   "drunk",
        location:  city
      )

      expect(char).to be_persisted
      expect(char.level).to eq(1)
      expect(char.strength).to eq(10)
      # description never ran, so properties contain only what the always-on
      # steps set: gender (grounded before stats, so it survives the fallback)
      # and lens (Lens.apply! runs in the fallback path).
      expect(char.properties.keys).to contain_exactly("gender", "lens")
      expect(%w[male female]).to include(char.properties["gender"])
      expect(Harness::Character::Lens::VALID).to include(char.properties["lens"])
    end

    it "writes both personality and appearance when description succeeds" do
      llm = llm_returning(stats: good_stats(level: 2))
      char = described_class.spawn(
        llm_grunt: llm,
        name:      "Marek",
        subrole:   "captain",
        location:  city
      )

      expect(char.properties["personality"]).to be_present
      expect(char.properties["appearance"]).to be_present
    end

    describe "gender grounding" do
      it "grounds gender from the name's pool membership (mechanical names round-trip)" do
        llm = llm_returning
        # "Astrid" is a nord female pool name; "Bjorn" is nord male.
        she = described_class.spawn(llm_grunt: llm, name: "Astrid", subrole: "smith", location: city)
        he  = described_class.spawn(llm_grunt: llm, name: "Bjorn",  subrole: "smith", location: city)
        expect(she.properties["gender"]).to eq("female")
        expect(he.properties["gender"]).to eq("male")
      end

      it "still sets a gender for a name in no pool (LLM-invented), so it's never nil" do
        char = described_class.spawn(llm_grunt: nil, name: "Zxqwflorn", subrole: "drunk", location: city)
        expect(%w[male female]).to include(char.properties["gender"])
      end

      it "is deterministic for an out-of-pool name given a fixed rng" do
        a = described_class.spawn(llm_grunt: nil, name: "Zxqwflorn", subrole: "x", location: city, rng: Random.new(7))
        b = described_class.spawn(llm_grunt: nil, name: "Zxqwflorn", subrole: "x", location: city, rng: Random.new(7))
        expect(a.properties["gender"]).to eq(b.properties["gender"])
      end

      it "respects a gender already set by the caller (no overwrite)" do
        # Even though "Astrid" reads female, an explicit caller-set gender wins.
        char = described_class.spawn(
          llm_grunt: nil, name: "Astrid", subrole: "smith", location: city,
          properties: { "gender" => "male" }
        )
        expect(char.properties["gender"]).to eq("male")
      end
    end

    it "keeps stats but skips description when only the description call fails" do
      llm = StubLLM.new { |prompt|
        if prompt.include?("generating a LEVEL and six ability scores")
          good_stats(level: 2)
        else
          "not json"
        end
      }

      char = described_class.spawn(
        llm_grunt: llm,
        name:      "Marek",
        subrole:   "captain",
        location:  city
      )

      expect(char.level).to eq(2)
      expect(char.strength).to eq(12)  # from good_stats
      expect(char.properties["personality"]).to be_nil
      expect(char.properties["appearance"]).to be_nil
    end

    it "passes the rolled scenario seed through to BOTH stats and description" do
      seen_prompts = []
      llm = StubLLM.new { |prompt|
        seen_prompts << prompt
        if prompt.include?("generating a LEVEL and six ability scores")
          good_stats
        else
          good_description
        end
      }

      rng = Random.new(2)
      described_class.spawn(
        llm_grunt: llm,
        name:      "Marek",
        subrole:   "barkeep",
        location:  city,
        rng:       rng
      )

      expect(seen_prompts.size).to eq(2)
      stats_prompt = seen_prompts.find { |p| p.include?("LEVEL and six ability scores") }
      desc_prompt  = seen_prompts.find { |p| p.include?("personality and a physical appearance") }
      expect(stats_prompt).to include("INPUT:")
      expect(desc_prompt).to include("INPUT:")
      # If a SCENARIO fired, both calls should see the same seed
      if stats_prompt.include?("SCENARIO:")
        expect(desc_prompt).to include("SCENARIO:")
      end
    end

    it "scenario rolls fire — at least one of N spawns hits a non-nothing scenario with a fixed RNG sweep" do
      seen_scenarios = []
      30.times do |i|
        llm = StubLLM.new { |prompt|
          seen_scenarios << "outlier" if prompt.include?("SCENARIO:")
          if prompt.include?("LEVEL and six ability scores") then good_stats else good_description end
        }
        described_class.spawn(
          llm_grunt: llm,
          name:      "NPC#{i}",
          subrole:   "barkeep",
          location:  city,
          rng:       Random.new(i)
        )
      end

      expect(seen_scenarios).not_to be_empty,
        "30 seeded spawns produced 0 outlier scenarios — Roller may not be wired into Hatchery.spawn"
    end

    it "passes the character's gender into the scenario roll context (for requires: { gender: ... } gating)" do
      llm = StubLLM.new { |prompt|
        if prompt.include?("LEVEL and six ability scores") then good_stats else good_description end
      }
      seen_context = nil
      allow(Harness::Scenarios::Roller).to receive(:roll).and_wrap_original do |orig, **kwargs|
        seen_context = kwargs[:context]
        orig.call(**kwargs)
      end

      described_class.spawn(
        llm_grunt:  llm,
        name:       "Marek",
        subrole:    "barkeep",
        location:   city,
        properties: { "gender" => "male" }
      )

      expect(seen_context).to eq({ gender: "male" })
    end

    it "end-to-end: a gender-gated scenario NEVER reaches the other gender and DOES reach its own" do
      table_path = Harness::Scenarios::Roller::TABLES_DIR.join("test_gender_gate.yml")
      File.write(table_path, <<~YAML)
        - id: nothing_interesting
          weight: 1
          prompt_seed: null
        - id: female_only
          weight: 99
          requires: { gender: female }
          prompt_seed: "SCENARIO: FEMALE_ONLY_MARKER"
      YAML
      Harness::Scenarios::Roller.reload!
      stub_const("Harness::Character::Hatchery::SCENARIO_TABLE", "test_gender_gate")

      spawn_and_collect = lambda do |gender, i|
        prompts = []
        llm = StubLLM.new { |prompt|
          prompts << prompt
          if prompt.include?("LEVEL and six ability scores") then good_stats else good_description end
        }
        described_class.spawn(
          llm_grunt:  llm,
          name:       "NPC-#{gender}-#{i}",
          subrole:    "barkeep",
          location:   city,
          properties: { "gender" => gender },
          rng:        Random.new(i)
        )
        prompts
      end

      male_prompts   = 20.times.flat_map { |i| spawn_and_collect.call("male", i) }
      female_prompts = 20.times.flat_map { |i| spawn_and_collect.call("female", i) }

      expect(male_prompts).not_to include(a_string_including("FEMALE_ONLY_MARKER"))
      expect(female_prompts.count { |p| p.include?("FEMALE_ONLY_MARKER") }).to be > 0
    ensure
      File.delete(table_path) if File.exist?(table_path)
      Harness::Scenarios::Roller.reload!
    end
  end

  describe ".find_or_spawn" do
    it "returns the existing row when find_attrs match (no re-materialization)" do
      existing = Npc.create!(name: "Marek", location: city, strength: 18, level: 7)
      called = false
      llm = StubLLM.new { |_p| called = true; good_stats }

      char = described_class.find_or_spawn(
        llm_grunt:  llm,
        find_attrs: { name: "Marek", location_id: city.id }
      )

      expect(char.id).to eq(existing.id)
      expect(char.strength).to eq(18)
      expect(char.level).to eq(7)
      expect(called).to be(false)
    end

    it "spawns fresh when no match exists" do
      llm = llm_returning(stats: good_stats(level: 4))

      char = described_class.find_or_spawn(
        llm_grunt:  llm,
        find_attrs: { name: "Marek", location_id: city.id }
      )

      expect(char).to be_persisted
      expect(char.name).to eq("Marek")
      expect(char.level).to eq(4)
    end
  end

  describe "encounter intent injection" do
    let(:combat_leaf) {
      Location.create!(name: "Defile", x: 0, y: 0,
                       properties: { "kind" => "wilderness_leaf", "encounter_type" => "combat" })
    }
    let(:discovery_leaf) {
      Location.create!(name: "Hermit cave", x: 0, y: 0,
                       properties: { "kind" => "wilderness_leaf", "encounter_type" => "discovery" })
    }

    it "merges role_intent into properties for combat encounter spawns" do
      char = described_class.spawn(llm_grunt: nil, name: "X", location: combat_leaf, rng: Random.new(1))
      expect(char.properties["role_intent"]).to match(/ambush.*demand.*coin/)
    end

    it "biases subrole toward hostile picks when caller passed nil subrole" do
      seen = (1..30).map { |seed|
        described_class.spawn(llm_grunt: nil, name: "X#{seed}", location: combat_leaf, rng: Random.new(seed)).subrole
      }.compact.uniq
      expect(seen).not_to be_empty
      expect(seen).to all(satisfy { |s| Harness::Encounters::RoleIntent::INTENT["combat"][:subrole_bias].include?(s) })
    end

    it "preserves caller's explicit subrole over the bias" do
      char = described_class.spawn(llm_grunt: nil, name: "X", subrole: "captain", location: combat_leaf, rng: Random.new(1))
      expect(char.subrole).to eq("captain")
      # role_intent still merges in regardless.
      expect(char.properties["role_intent"]).to be_present
    end

    it "preserves caller's explicit role_intent (no overwrite)" do
      char = described_class.spawn(llm_grunt: nil, name: "X", location: combat_leaf,
                                   properties: { "role_intent" => "wants tribute and recognition" }, rng: Random.new(1))
      expect(char.properties["role_intent"]).to eq("wants tribute and recognition")
    end

    it "uses the discovery role_intent for discovery encounters" do
      char = described_class.spawn(llm_grunt: nil, name: "X", location: discovery_leaf, rng: Random.new(1))
      expect(char.properties["role_intent"]).to match(/wary.*protective/)
    end

    it "is a no-op for non-encounter locations" do
      plain = Location.create!(name: "Hall")
      char  = described_class.spawn(llm_grunt: nil, name: "X", location: plain, rng: Random.new(1))
      expect(char.properties["role_intent"]).to be_nil
    end

    it "is a no-op for the player path" do
      # Player.create with location_id at a combat leaf shouldn't get a hostile subrole.
      player = described_class.spawn(llm_grunt: nil, type: ::Player, name: "Hero",
                                     location: combat_leaf, character_class: "fighter", rng: Random.new(1))
      expect(player).to be_a(::Player)
      expect(player.properties["role_intent"]).to be_nil
    end
  end

  describe "inventory rolling" do
    it "rolls the deterministic player starter kit on materialize!" do
      player = Player.create!(name: "Hero", location: city, character_class: "fighter")
      described_class.materialize!(player, llm_grunt: nil)
      expect(player.items.pluck(:subrole).sort).to eq(%w[longblade medium_armor shield].sort)
    end

    it "rolls NPC inventory in the LLM-success path (fighter table mostly produces items)" do
      with_items = 0
      10.times do |seed|
        llm = llm_returning(stats: good_stats(level: 2, character_class: "fighter"))
        char = described_class.spawn(
          llm_grunt: llm,
          name:      "Korr#{seed}",
          subrole:   "guard",
          location:  city,
          rng:       Random.new(seed)
        )
        with_items += 1 if char.items.exists?
      end
      # Fighter table: nothing=5/100. So ~95% of seeds should roll something.
      expect(with_items).to be >= 5
    end

    it "rolls NPC inventory even when llm_grunt is nil (defaults path: commoner)" do
      Npc.create!(name: "Patron", subrole: "drunk", location: city).then do |npc|
        described_class.materialize!(npc, llm_grunt: nil, rng: Random.new(0))
        # commoner table has 70% nothing — so most seeds produce 0 items.
        # Just assert no error raised + character_class is commoner.
        expect(npc.character_class).to eq("commoner")
      end
    end

    it "is idempotent — re-materializing does not double-stock inventory" do
      player = Player.create!(name: "Hero", location: city, character_class: "fighter")
      described_class.materialize!(player, llm_grunt: nil)
      first  = player.items.count
      described_class.materialize!(player, llm_grunt: nil)
      expect(player.items.count).to eq(first)
    end

    it "swallows inventory roll failures (logs + moves on)" do
      allow(::Harness::Items::Inventory).to receive(:roll_for_player).and_raise(StandardError, "boom")
      player = Player.create!(name: "Hero", location: city, character_class: "fighter")
      expect { described_class.materialize!(player, llm_grunt: nil) }.not_to raise_error
      expect(player.reload).to be_persisted
    end
  end

  describe ".materialize!" do
    it "is a no-op for Player rows" do
      player = Player.create!(name: "Hero", location: city)
      called = false
      llm = StubLLM.new { |_p| called = true; good_stats }

      out = described_class.materialize!(player, llm_grunt: llm)
      expect(out).to eq(player)
      expect(called).to be(false)
      expect(player.reload.strength).to be_nil
    end

    it "passes prose_context through to BOTH the stats and description materializers" do
      stats_user = nil
      desc_user  = nil
      llm = StubLLM.new { |prompt|
        if prompt.include?("LEVEL and six ability scores")
          stats_user = prompt
          good_stats
        else
          desc_user = prompt
          good_description
        end
      }
      npc = Npc.create!(name: "Marek", subrole: "captain", location: city)

      described_class.materialize!(npc, llm_grunt: llm, prose_context: "lost his son in a storm three months ago")

      expect(stats_user).to include("lost his son in a storm three months ago")
      expect(desc_user).to  include("lost his son in a storm three months ago")
    end
  end
end
