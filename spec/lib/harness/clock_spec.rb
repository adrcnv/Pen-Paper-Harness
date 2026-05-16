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

  describe "scene_dirty trigger" do
    let(:active) {
      Harness::Scene::Active.new(
        location: loc, snapshot: nil, narrations: [], internal_state: {},
        entered_at_game_time: 1000
      )
    }

    before { context.active_scene = active }

    it "does NOT set scene_dirty when in-scene time is below threshold" do
      described_class.advance(context, minutes: 30, reason: "test", logger: logger)
      expect(context.scene_dirty).to be(false)
    end

    it "sets scene_dirty when in-scene time crosses threshold (60min)" do
      described_class.advance(context, minutes: 65, reason: "test", logger: logger)
      expect(context.scene_dirty).to be(true)
    end

    it "sets scene_dirty exactly at threshold" do
      described_class.advance(context, minutes: 60, reason: "test", logger: logger)
      expect(context.scene_dirty).to be(true)
    end

    it "accumulates across multiple advances" do
      described_class.advance(context, minutes: 30, reason: "first",  logger: logger)
      expect(context.scene_dirty).to be(false)
      described_class.advance(context, minutes: 35, reason: "second", logger: logger)
      expect(context.scene_dirty).to be(true)
    end

    it "does not set scene_dirty when no active scene" do
      context.active_scene = nil
      described_class.advance(context, minutes: 1000, reason: "test", logger: logger)
      expect(context.scene_dirty).to be(false)
    end

    it "does not re-fire if scene is already dirty (idempotent)" do
      context.scene_dirty = true
      expect {
        described_class.advance(context, minutes: 5, reason: "test", logger: logger)
      }.not_to change { context.scene_dirty }
    end
  end

  describe "mid-scene pending-appearance firing" do
    let(:active) {
      Harness::Scene::Active.new(
        location: loc, snapshot: nil, narrations: [], internal_state: {},
        entered_at_game_time: 1000
      )
    }
    let(:player)  { Player.create!(name: "Hero", location: loc) }
    let(:visitor) { Npc.create!(name: "Vance", location: nil, character_class: "fighter") }

    before do
      player
      context.active_scene = active
    end

    it "fires unresolved PAs whose earliest_at came due during this tick" do
      PendingAppearance.create!(
        target_character: player, actor_character: visitor, anchor_location: loc,
        scope: "city", earliest_at: 1010, intent_text: "shows up to deliver news"
      )

      described_class.advance(context, minutes: 15, reason: "test", logger: logger)

      visitor.reload
      expect(visitor.location_id).to eq(loc.id)
      expect(context.scene_dirty).to be(true)
    end

    it "does NOT fire PAs whose earliest_at is still in the future" do
      PendingAppearance.create!(
        target_character: player, actor_character: visitor, anchor_location: loc,
        scope: "city", earliest_at: 9999, intent_text: "later"
      )

      described_class.advance(context, minutes: 15, reason: "test", logger: logger)

      visitor.reload
      expect(visitor.location_id).to be_nil
      expect(context.scene_dirty).to be(false)
    end

    it "does NOT fire PAs out of scope (different city)" do
      other_city = Location.create!(name: "Other")
      PendingAppearance.create!(
        target_character: player, actor_character: visitor, anchor_location: other_city,
        scope: "local", earliest_at: 1010, intent_text: "elsewhere"
      )

      described_class.advance(context, minutes: 15, reason: "test", logger: logger)

      visitor.reload
      expect(visitor.location_id).to be_nil
    end

    it "is a no-op when there's no active scene" do
      context.active_scene = nil
      PendingAppearance.create!(
        target_character: player, actor_character: visitor, anchor_location: loc,
        scope: "city", earliest_at: 1010, intent_text: "x"
      )

      expect {
        described_class.advance(context, minutes: 15, reason: "test", logger: logger)
      }.not_to raise_error
      expect(visitor.reload.location_id).to be_nil
    end

    it "is a no-op when no Player exists" do
      Player.delete_all
      expect {
        described_class.advance(context, minutes: 15, reason: "test", logger: logger)
      }.not_to raise_error
      expect(context.game_time).to eq(1015)
    end

    it "swallows resolver failures (logs + advance still completes)" do
      allow(Harness::Scene::PendingAppearanceResolver).to receive(:new).and_raise(StandardError, "boom")
      expect {
        described_class.advance(context, minutes: 5, reason: "test", logger: logger)
      }.not_to raise_error
      expect(context.game_time).to eq(1005)
    end
  end
end
