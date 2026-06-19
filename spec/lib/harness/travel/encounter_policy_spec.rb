require "rails_helper"

RSpec.describe Harness::Travel::EncounterPolicy do
  let(:journey) {
    Journey.new(
      destination_id: 1, origin_x: 0, origin_y: 0,
      cursor_x: 0, cursor_y: 0,
      started_at_game_time: 0, elapsed_minutes: 0,
      cooldown_until_game_time: 0
    )
  }

  describe ".fires?" do
    it "fires when rng beats the rate AND the journey is past cooldown" do
      always_fire = Random.new.tap { |r| allow(r).to receive(:rand).and_return(0.05) }
      expect(described_class.fires?(journey: journey, current_game_time: 100, rng: always_fire)).to be(true)
    end

    it "does not fire when rng exceeds the rate" do
      never_fire = Random.new.tap { |r| allow(r).to receive(:rand).and_return(0.99) }
      expect(described_class.fires?(journey: journey, current_game_time: 100, rng: never_fire)).to be(false)
    end

    it "does not fire while cooldown_until_game_time has not elapsed" do
      journey.cooldown_until_game_time = 200
      always_fire = Random.new.tap { |r| allow(r).to receive(:rand).and_return(0.0) }
      expect(described_class.fires?(journey: journey, current_game_time: 150, rng: always_fire)).to be(false)
    end

    it "fires again once cooldown has expired" do
      journey.cooldown_until_game_time = 200
      always_fire = Random.new.tap { |r| allow(r).to receive(:rand).and_return(0.0) }
      expect(described_class.fires?(journey: journey, current_game_time: 250, rng: always_fire)).to be(true)
    end
  end

  describe ".pick_bucket" do
    # Current weights (see encounter_policy.rb): social 0.70 / discovery 0.15
    # / combat 0.15. Effective per-segment combat rate = ENCOUNTER_RATE × 0.15.
    it "distributes across all three buckets with social weighted highest" do
      buckets = 2000.times.map { described_class.pick_bucket }
      social_count    = buckets.count("social")
      discovery_count = buckets.count("discovery")
      combat_count    = buckets.count("combat")
      # Generous bounds — Ruby's rand is acceptable as a smoke check, not a
      # statistical test. 70/15/15 should land roughly there over 2000 rolls.
      expect(social_count).to    be_between(1200, 1600)  # ~1400 expected
      expect(discovery_count).to be_between( 200,  450)  # ~300 expected
      expect(combat_count).to    be_between( 200,  450)  # ~300 expected
    end

    it "respects custom weights when callers pass alternate distributions" do
      # Forward-compat test: when weights are rebalanced we want random
      # picking still to behave correctly. Here we exercise the raw
      # weighted-pick logic via a local stub of BUCKET_WEIGHTS.
      stub_const("Harness::Travel::EncounterPolicy::BUCKET_WEIGHTS", { "social" => 0.5, "discovery" => 0.5 })
      buckets = 1000.times.map { described_class.pick_bucket }
      social_count = buckets.count("social")
      expect(social_count).to be_between(400, 600)
    end
  end
end
