require "rails_helper"

RSpec.describe Harness::Scene::Active do
  let(:loc) { Location.create!(name: "Tavern") }

  def make(agendas: {})
    described_class.new(
      location:             loc,
      snapshot:             nil,
      narrations:           [],
      internal_state:       {},
      agendas:              agendas,
      extras:               [],
      entered_at_game_time: 0
    )
  end

  describe "agenda text (inert content — no pressure tracking)" do
    it "agenda_for returns the NPC's agenda text" do
      a = make(agendas: { 5 => "wants this" })
      expect(a.agenda_for(5)).to eq("wants this")
    end

    it "agenda_for returns nil for an NPC without an agenda" do
      a = make(agendas: { 5 => "wants this" })
      expect(a.agenda_for(99)).to be_nil
    end

    it "no longer carries silent-turn / overdue machinery" do
      a = make(agendas: { 5 => "wants this" })
      expect(a).not_to respond_to(:tick_agendas!)
      expect(a).not_to respond_to(:agenda_overdue?)
      expect(a).not_to respond_to(:agenda_silent_turns)
    end
  end

  describe "combat sub-mode" do
    it "in_combat? false until start_combat!" do
      a = make
      expect(a.in_combat?).to be(false)
      expect(a.combat).to be_nil
    end

    it "start_combat! initializes a fresh Combat::State" do
      a = make
      a.start_combat!
      expect(a.in_combat?).to be(true)
      expect(a.combat).to be_a(Harness::Combat::State)
      expect(a.combat.round).to eq(1)
    end

    it "end_combat! clears the state" do
      a = make
      a.start_combat!
      a.combat.add_combatant(7, side: "marauders")
      a.end_combat!
      expect(a.in_combat?).to be(false)
      expect(a.combat).to be_nil
    end
  end
end
