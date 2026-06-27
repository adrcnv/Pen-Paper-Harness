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
