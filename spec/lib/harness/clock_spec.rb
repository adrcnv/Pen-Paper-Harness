require "rails_helper"

RSpec.describe Harness::Clock do
  let(:logger)  { Logger.new(IO::NULL) }
  let(:loc)     { Location.create!(name: "Tavern") }
  let(:context) { Harness::Turn::Context.new(player_location: loc, game_time: 1000) }

  describe ".advance" do
    it "increments game_time by minutes" do
      described_class.advance(context, minutes: 15, reason: "test", logger: logger)
      expect(context.game_time).to eq(1015)
    end

    it "is a no-op for zero minutes" do
      described_class.advance(context, minutes: 0, reason: "test", logger: logger)
      expect(context.game_time).to eq(1000)
    end

    it "raises ArgumentError for negative minutes" do
      expect {
        described_class.advance(context, minutes: -5, reason: "test", logger: logger)
      }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for non-integer minutes" do
      expect {
        described_class.advance(context, minutes: 1.5, reason: "test", logger: logger)
      }.to raise_error(ArgumentError)
    end
  end

  describe ".phase" do
    it "maps hours to phases across the day (boundaries: 6/11/17/22)" do
      expect(described_class.phase(0 * 60)).to eq(:night)      # midnight
      expect(described_class.phase(5 * 60 + 59)).to eq(:night)
      expect(described_class.phase(6 * 60)).to eq(:morning)
      expect(described_class.phase(10 * 60 + 59)).to eq(:morning)
      expect(described_class.phase(11 * 60)).to eq(:day)
      expect(described_class.phase(16 * 60 + 59)).to eq(:day)
      expect(described_class.phase(17 * 60)).to eq(:evening)
      expect(described_class.phase(21 * 60 + 59)).to eq(:evening)
      expect(described_class.phase(22 * 60)).to eq(:night)
    end

    it "wraps across days (game_time is absolute minutes)" do
      expect(described_class.phase(3 * 1440 + 12 * 60)).to eq(:day)
      expect(described_class.phase(7 * 1440 + 23 * 60)).to eq(:night)
    end

    it "treats nil as minute zero (night)" do
      expect(described_class.phase(nil)).to eq(:night)
    end
  end

  describe "scene_dirty (no accrual-driven rebuild)" do
    let(:active) {
      Harness::Scene::Active.new(
        location: loc, snapshot: nil, narrations: [], internal_state: {},
        entered_at_game_time: 1000
      )
    }

    before { context.active_scene = active }

    # The old behavior — accrued conversation/action time crossing 60min
    # forcing a same-location rebuild — was the "scene whiplash" failure and
    # has been removed. Clock.advance NEVER dirties the scene from accrued
    # time, however much piles up. Explicit skips (pass_time) and movement
    # (transition/travel) own the rebuild now.
    it "does NOT set scene_dirty from accrued time, even far past the old 60min threshold" do
      described_class.advance(context, minutes: 65,  reason: "conversation", logger: logger)
      expect(context.scene_dirty).to be(false)
      described_class.advance(context, minutes: 500, reason: "more talk",    logger: logger)
      expect(context.scene_dirty).to be(false)
    end

    it "leaves an already-dirty scene dirty (doesn't clear it)" do
      context.scene_dirty = true
      described_class.advance(context, minutes: 5, reason: "test", logger: logger)
      expect(context.scene_dirty).to be(true)
    end
  end
end
