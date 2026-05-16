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

  describe "agenda silent-turn tracking" do
    it "starts with empty silent counters" do
      a = make(agendas: { 5 => "wants this" })
      expect(a.agenda_silent_turns).to eq({})
      expect(a.agenda_overdue?(5)).to be(false)
    end

    it "tick! increments silent counters for non-actors with agendas" do
      a = make(agendas: { 5 => "wants this", 7 => "wants that" })
      a.tick_agendas!([])
      expect(a.agenda_silent_turns[5]).to eq(1)
      expect(a.agenda_silent_turns[7]).to eq(1)
    end

    it "tick! resets silent counter to 0 for NPCs who acted" do
      a = make(agendas: { 5 => "wants this", 7 => "wants that" })
      a.tick_agendas!([])
      a.tick_agendas!([ 5 ])
      expect(a.agenda_silent_turns[5]).to eq(0)
      expect(a.agenda_silent_turns[7]).to eq(2)
    end

    it "tick! ignores NPCs without agendas" do
      a = make(agendas: { 5 => "wants this" })
      a.tick_agendas!([])
      expect(a.agenda_silent_turns).to eq({ 5 => 1 })
      expect(a.agenda_silent_turns).not_to have_key(99)
    end

    it "agenda_overdue? returns true once silent count crosses threshold" do
      a = make(agendas: { 5 => "wants this" })
      Harness::Scene::AGENDA_PUSH_THRESHOLD.times { a.tick_agendas!([]) }
      expect(a.agenda_overdue?(5)).to be(true)
    end

    it "agenda_overdue? returns false for NPCs without agendas" do
      a = make(agendas: {})
      a.tick_agendas!([])
      a.tick_agendas!([])
      a.tick_agendas!([])
      expect(a.agenda_overdue?(5)).to be(false)
    end

    it "agenda_overdue? returns false until threshold reached" do
      a = make(agendas: { 5 => "wants this" })
      (Harness::Scene::AGENDA_PUSH_THRESHOLD - 1).times { a.tick_agendas!([]) }
      expect(a.agenda_overdue?(5)).to be(false)
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
