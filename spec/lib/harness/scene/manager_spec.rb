require "rails_helper"

RSpec.describe Harness::Scene::Manager do
  let(:city)    { Location.create!(name: "Saltmere") }
  let(:tavern)  { Location.create!(name: "Tavern", parent: city) }
  let(:warehouse) { Location.create!(name: "Warehouse", parent: city) }
  let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: tavern) }
  let(:logger)  { Logger.new(IO::NULL) }

  # Stub LLM for internal-state prompts (the only LLM call at scene entry
  # in the post-extractor world). Returns a flat mood line per present NPC.
  let(:stub_llm) {
    StubLLM.new { |prompt|
      if prompt.include?("INTERNAL STATE")
        states = present_npc_names.each_with_object({}) { |n, h|
          h[n] = "#{n} is in a perfectly ordinary mood today, neither up nor down."
        }
        { "internal_states" => states }.to_json
      else
        # Catch-up sim or other grunt calls — empty by default.
        { "events" => [] }.to_json
      end
    }
  }

  let(:present_npc_names) { [] }

  let(:context) {
    Harness::Turn::Context.new(player_location: tavern, llm_client: stub_llm)
  }

  let(:manager) { described_class.new(context: context, logger: logger) }

  describe "#enter / #ensure_entered" do
    let(:present_npc_names) { [ "Maren" ] }

    it "assembles the scene at the player's location and stores it" do
      maren  # ensure present
      active = manager.ensure_entered
      expect(active).not_to be_nil
      expect(active.location).to eq(tavern)
      expect(active.present_characters).to include(maren)
      expect(context.active_scene).to eq(active)
    end

    it "ensure_entered is idempotent at the same location" do
      maren
      first  = manager.ensure_entered
      second = manager.ensure_entered
      expect(second).to equal(first)  # same object
    end

    it "ensure_entered re-enters when player_location changed" do
      maren
      first = manager.ensure_entered
      context.player_location = warehouse
      # warehouse is empty — no NPCs there. Update the names accordingly.
      allow(stub_llm).to receive(:call).and_call_original  # already a proc; placeholder
      second = manager.ensure_entered
      expect(second.location).to eq(warehouse)
      expect(second).not_to equal(first)
    end

    it "narrations start empty" do
      maren
      expect(manager.ensure_entered.narrations).to eq([])
    end

    it "populates internal_state for present NPCs" do
      maren
      active = manager.ensure_entered
      expect(active.internal_state).to include(maren.id)
      expect(active.state_for(maren.id)).to match(/Maren/)
    end

    it "skips internal-state generation when llm_grunt is nil" do
      maren
      context.llm_grunt  = nil
      context.llm_nuance = nil
      active = manager.ensure_entered
      expect(active.internal_state).to eq({})
    end

    it "skips internal-state generation when no NPCs are present" do
      # warehouse has no characters
      context.player_location = warehouse
      active = manager.ensure_entered
      expect(active.internal_state).to eq({})
    end

    it "fires LocationSeeder on enter and marks the location as seeded" do
      maren
      expect(Harness::Items::LocationSeeder).to receive(:seed!).with(tavern, rng: anything).and_call_original
      manager.ensure_entered
      expect(tavern.reload.properties["items_seeded"]).to be(true)
    end

    it "swallows LocationSeeder errors (logs + scene entry continues)" do
      maren
      allow(Harness::Items::LocationSeeder).to receive(:seed!).and_raise(StandardError, "boom")
      expect { manager.ensure_entered }.not_to raise_error
    end
  end

  describe "auto-materialize at scene entry" do
    # Pin the rng so target_count and Array#sample are deterministic. seed=1
    # picks 3 (which is the modal value of TARGET_COUNT_DISTRIBUTION anyway).
    let(:fixed_rng) { Random.new(1) }
    let(:wilderness) { Location.create!(name: "Old Mill Pond", description: "a quiet pond off the road", x: 12.0, y: 5.0, biome: "lowland") }

    let(:materializer_double) {
      instance_double(Harness::Scene::Materializer).tap do |m|
        allow(m).to receive(:materialize) { |location:, target_count:|
          # Simulate a successful spawn: create N NPCs at the location so
          # subsequent assembler queries see them.
          target_count.times do |i|
            Npc.create!(name: "Spawned-#{i}", subrole: "patron", location: location)
          end
          { promoted: [], spawned: [] }
        }
      end
    }

    # Stub InternalState too — these specs are about Materializer wiring;
    # we don't want a fragile name-list mismatch to fail the test when the
    # spawned NPCs have names the default stub doesn't know about.
    let(:internal_state_double) {
      instance_double(Harness::Scene::InternalState).tap do |is|
        allow(is).to receive(:generate).and_return(
          Harness::Scene::InternalState::Result.new(internal_state: {}, agendas: {}, extras: [])
        )
      end
    }

    before do
      allow(Harness::Scene::Materializer).to receive(:new).and_return(materializer_double)
      allow(Harness::Scene::InternalState).to receive(:new).and_return(internal_state_double)
    end

    it "fires Materializer when a fresh sublocation has zero NPCs" do
      context.player_location = warehouse
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      mgr.ensure_entered
      expect(materializer_double).to have_received(:materialize).with(location: warehouse, target_count: be_between(3, 6))
    end

    it "skips Materializer when the sublocation already has at least one NPC" do
      maren  # Maren is at the tavern
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      mgr.ensure_entered
      expect(materializer_double).not_to have_received(:materialize)
    end

    it "fires Materializer for untagged top-level locations (worldgen cities promote class-2 founders + spawn locals)" do
      # Pre-class-2-revival, Genesis materialized founders directly at the
      # city tier so Materializer was redundant here. With class-2 default,
      # founders are strings until promoted — Materializer is the only
      # path that promotes them, so it must fire on city entry too.
      context.player_location = wilderness
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      mgr.ensure_entered
      expect(materializer_double).to have_received(:materialize).with(location: wilderness, target_count: be_between(3, 6))
    end

    it "fires Materializer for wilderness_leaf-tagged top-level locations (player-proposed leaves + encounter spawns)" do
      leaf = Location.create!(name: "Old Mill Pond Hermitage", description: "a quiet hermitage", x: 12.0, y: 5.0, biome: "lowland", properties: { "kind" => "wilderness_leaf" })
      context.player_location = leaf
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      mgr.ensure_entered
      expect(materializer_double).to have_received(:materialize).with(location: leaf, target_count: be_between(2, 4))
    end

    it "skips Materializer when llm_grunt is missing" do
      context.player_location = warehouse
      context.llm_grunt  = nil
      context.llm_nuance = nil
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      mgr.ensure_entered
      expect(materializer_double).not_to have_received(:materialize)
    end

    it "still completes scene entry when Materializer raises (failure non-fatal)" do
      context.player_location = warehouse
      allow(materializer_double).to receive(:materialize).and_raise(StandardError, "LLM gave up")
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      active = mgr.ensure_entered
      expect(active).not_to be_nil
      expect(active.location).to eq(warehouse)
      expect(active.present_characters).to eq([])
    end

    it "explicit materialize_target overrides the auto-target distribution" do
      context.player_location = warehouse
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      mgr.ensure_entered(materialize_target: 7)
      expect(materializer_double).to have_received(:materialize).with(location: warehouse, target_count: 7)
    end

    it "explicit materialize_target fires even when location already has NPCs" do
      maren
      mgr = described_class.new(context: context, logger: logger, rng: fixed_rng)
      mgr.ensure_entered(materialize_target: 5)
      expect(materializer_double).to have_received(:materialize).with(location: tavern, target_count: 5)
    end
  end

  describe "background-sim eager fires (deep-thesis behavior)" do
    # Genesis, CatchUp, and CharacterCatchUp fire automatically on scene entry
    # to give the world its felt-history texture. Cost is real (~$0.10 + $0.05
    # + $0.05 per first-city entry); the design accepts that tradeoff.
    # Generators are wired through llm_grunt and skip cleanly when it's nil.
    let(:hollowmere) { Location.create!(name: "Hollowmere", description: "a hollow village", x: 35.0, y: 12.0, biome: "lowland") }

    it "fires Genesis on first entry to a worldgen-rooted city" do
      hollowmere
      ctx = Harness::Turn::Context.new(player_location: hollowmere, game_time: 1000, llm_client: stub_llm)
      mgr = described_class.new(context: ctx, logger: logger)

      gen_double = instance_double(Harness::Genesis::Generator)
      allow(gen_double).to receive(:generate).and_return([])
      expect(Harness::Genesis::Generator).to receive(:new).and_return(gen_double)
      mgr.ensure_entered
    end

    it "skips Genesis when the location already has events (idempotent)" do
      hollowmere
      Event.create!(game_time: 500, scope: "local", location: hollowmere, details: {})
      ctx = Harness::Turn::Context.new(player_location: hollowmere, game_time: 1000, llm_client: stub_llm)
      mgr = described_class.new(context: ctx, logger: logger)

      expect(Harness::Genesis::Generator).not_to receive(:new)
      mgr.ensure_entered
    end

    it "skips Genesis for sublocations (parent_id present)" do
      tavern  # sublocation of city
      ctx = Harness::Turn::Context.new(player_location: tavern, llm_client: stub_llm)
      mgr = described_class.new(context: ctx, logger: logger)

      expect(Harness::Genesis::Generator).not_to receive(:new)
      mgr.ensure_entered
    end

    it "skips Genesis when llm_grunt is nil" do
      hollowmere
      ctx = Harness::Turn::Context.new(player_location: hollowmere, game_time: 1000)
      mgr = described_class.new(context: ctx, logger: logger)

      expect(Harness::Genesis::Generator).not_to receive(:new)
      mgr.ensure_entered
    end

    it "fires CatchUp on entry (skips internally on no prior events / short gap)" do
      hollowmere
      ctx = Harness::Turn::Context.new(player_location: hollowmere, game_time: 1000, llm_client: stub_llm)
      mgr = described_class.new(context: ctx, logger: logger)

      catchup_double = instance_double(Harness::CatchUp::Generator)
      allow(catchup_double).to receive(:generate).and_return([])
      expect(Harness::CatchUp::Generator).to receive(:new).and_return(catchup_double)
      mgr.ensure_entered
    end

    context "with a present NPC" do
      let(:present_npc_names) { [ "Maren" ] }

      it "fires CharacterCatchUp on entry" do
        maren  # present at tavern
        ctx = Harness::Turn::Context.new(player_location: tavern, llm_client: stub_llm)
        mgr = described_class.new(context: ctx, logger: logger)

        ccu_double = instance_double(Harness::Scene::CharacterCatchUp::Generator)
        allow(ccu_double).to receive(:generate).and_return([])
        expect(Harness::Scene::CharacterCatchUp::Generator).to receive(:new).and_return(ccu_double)
        mgr.ensure_entered
      end
    end

    it "still completes scene entry when generators raise mid-call (failure non-fatal)" do
      hollowmere
      bad_llm = StubLLM.new { |_p| raise "transient LLM blowup" }
      ctx = Harness::Turn::Context.new(player_location: hollowmere, game_time: 1000, llm_client: bad_llm)
      mgr = described_class.new(context: ctx, logger: logger)

      active = nil
      expect { active = mgr.ensure_entered }.not_to raise_error
      expect(active).not_to be_nil
      expect(active.location).to eq(hollowmere)
    end
  end

  describe "#record_narration" do
    it "appends to the active scene's narration list" do
      manager.ensure_entered
      manager.record_narration("hi", "you walk in")
      expect(manager.active.narrations).to eq([ { "input" => "hi", "narration" => "you walk in" } ])
    end

    it "is a no-op when no scene is active" do
      expect { manager.record_narration("x", "y") }.not_to raise_error
    end
  end

  describe "#exit" do
    let(:present_npc_names) { [ "Maren" ] }

    it "tags present characters as witnesses on events committed during the scene window" do
      maren
      manager.ensure_entered
      # Simulate Phase 1 having committed an event at the tavern during the scene
      Event.create!(game_time: context.game_time, scope: "personal", location: tavern, details: { "summary" => "x" })

      added = manager.exit
      expect(added).to eq(1)
      expect(EventParticipant.where(role: "witness").count).to eq(1)
      expect(manager.active).to be_nil
      expect(context.active_scene).to be_nil
    end

    it "is a no-op when no events fall in the scene window" do
      maren
      manager.ensure_entered
      added = manager.exit
      expect(added).to eq(0)
      expect(manager.active).to be_nil
    end

    it "doesn't require llm_grunt (witness tagging is mechanical)" do
      maren
      manager.ensure_entered
      Event.create!(game_time: context.game_time, scope: "personal", location: tavern, details: {})
      context.llm_grunt  = nil
      context.llm_nuance = nil
      added = manager.exit
      expect(added).to eq(1)
      expect(manager.active).to be_nil
    end

    it "is a no-op when no scene is active" do
      expect { manager.exit }.not_to raise_error
    end
  end
end
