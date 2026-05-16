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
    # NOTE: PLAYTEST MODE — combat weight is 1.0, others 0. Every fired
    # encounter is currently a fight. When weights are dialed back to the
    # long-term ratio (social 0.55 / discovery 0.30 / combat 0.15) these
    # tests should be re-tuned to assert the distribution.
    it "picks combat in playtest mode (weight 1.0, others 0)" do
      buckets = 200.times.map { described_class.pick_bucket }
      expect(buckets.uniq).to eq([ "combat" ])
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
