require "rails_helper"

RSpec.describe Harness::Combat::State do
  subject(:state) { described_class.new }

  describe "initial state" do
    it "starts at round 1, no combatants, no initiative" do
      expect(state.round).to eq(1)
      expect(state.initiative).to eq([])
      expect(state.initiative_index).to eq(0)
      expect(state.sides).to eq({})
      expect(state.positions).to eq({})
      expect(state.engaged_with).to eq({})
      expect(state.acted_this_round).to eq([])
      expect(state.moved_this_round).to eq([])
      expect(state.watchers).to eq([])
      expect(state.evicted_character_ids).to eq([])
      expect(state.evicted_extras).to eq([])
    end
  end

  describe "#add_combatant" do
    it "registers side + position" do
      state.add_combatant(7, side: "marauders")
      expect(state.combatant?(7)).to be(true)
      expect(state.side_of(7)).to eq("marauders")
      expect(state.position_of(7)).to eq("near")
    end

    it "rejects unknown position" do
      expect { state.add_combatant(7, side: "marauders", position: "behind") }
        .to raise_error(ArgumentError)
    end

    it "string ids are coerced to integers" do
      state.add_combatant("7", side: "marauders")
      expect(state.combatant?(7)).to be(true)
      expect(state.side_of("7")).to eq("marauders")
    end
  end

  describe "#remove_combatant!" do
    it "clears side, position, engagement, initiative slot, and round tokens" do
      state.add_combatant(1, side: "a")
      state.add_combatant(2, side: "b")
      state.engage!(1, 2)
      state.initiative = [1, 2]
      state.mark_acted!(1)
      state.mark_moved!(1)

      state.remove_combatant!(1)

      expect(state.combatant?(1)).to be(false)
      expect(state.position_of(1)).to be_nil
      expect(state.engaged_with_of(1)).to be_nil
      expect(state.engaged_with_of(2)).to be_nil
      expect(state.initiative).to eq([2])
      expect(state.acted?(1)).to be(false)
      expect(state.moved?(1)).to be(false)
    end
  end

  describe "engagement" do
    it "engage! is symmetric and sets both positions to engaged" do
      state.add_combatant(1, side: "a")
      state.add_combatant(2, side: "b")
      state.engage!(1, 2)
      expect(state.engaged_with_of(1)).to eq(2)
      expect(state.engaged_with_of(2)).to eq(1)
      expect(state.position_of(1)).to eq("engaged")
      expect(state.position_of(2)).to eq("engaged")
    end

    it "disengage! clears both sides of the edge" do
      state.add_combatant(1, side: "a")
      state.add_combatant(2, side: "b")
      state.engage!(1, 2)
      state.disengage!(1)
      expect(state.engaged_with_of(1)).to be_nil
      expect(state.engaged_with_of(2)).to be_nil
    end
  end

  describe "round tokens" do
    it "mark_acted! and mark_moved! are idempotent" do
      state.mark_acted!(5)
      state.mark_acted!(5)
      state.mark_moved!(5)
      state.mark_moved!(5)
      expect(state.acted_this_round).to eq([5])
      expect(state.moved_this_round).to eq([5])
    end

    it "slot_complete? requires both tokens" do
      expect(state.slot_complete?(5)).to be(false)
      state.mark_acted!(5)
      expect(state.slot_complete?(5)).to be(false)
      state.mark_moved!(5)
      expect(state.slot_complete?(5)).to be(true)
    end
  end

  describe "initiative" do
    before do
      state.initiative = [4, 1, 7, 9]
    end

    it "current_actor_id reads at initiative_index" do
      expect(state.current_actor_id).to eq(4)
      state.advance_slot!
      expect(state.current_actor_id).to eq(1)
    end

    it "round_complete? after the last slot" do
      3.times { state.advance_slot! }
      expect(state.round_complete?).to be(false)
      state.advance_slot!
      expect(state.round_complete?).to be(true)
    end

    it "end_round! increments round, resets index and tokens" do
      state.mark_acted!(4)
      state.mark_moved!(4)
      4.times { state.advance_slot! }
      state.end_round!
      expect(state.round).to eq(2)
      expect(state.initiative_index).to eq(0)
      expect(state.acted_this_round).to be_empty
      expect(state.moved_this_round).to be_empty
      expect(state.initiative).to eq([4, 1, 7, 9])
    end

    it "insert_initiative_after_current! splices a slot in next" do
      state.insert_initiative_after_current!(99)
      expect(state.initiative).to eq([4, 99, 1, 7, 9])
    end
  end

  describe "watchers" do
    it "add_watcher tracks the id without making them a combatant" do
      state.add_watcher(12)
      expect(state.watcher?(12)).to be(true)
      expect(state.combatant?(12)).to be(false)
    end

    it "promote_watcher! moves them onto a side as near combatant" do
      state.add_watcher(12)
      state.promote_watcher!(12, side: "player_party")
      expect(state.watcher?(12)).to be(false)
      expect(state.combatant?(12)).to be(true)
      expect(state.side_of(12)).to eq("player_party")
      expect(state.position_of(12)).to eq("near")
    end
  end

  describe "eviction tracking" do
    it "records extras as descriptions and characters as ids" do
      state.record_evicted_extra("a fisherman in the corner")
      state.record_evicted_character(8)
      expect(state.evicted_extras).to eq(["a fisherman in the corner"])
      expect(state.evicted_character_ids).to eq([8])
    end
  end
end
