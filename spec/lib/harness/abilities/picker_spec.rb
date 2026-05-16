require "rails_helper"
require "stringio"

RSpec.describe Harness::Abilities::Picker do
  let(:city) { Location.create!(name: "Saltmere") }
  let(:logger) { Logger.new(IO::NULL) }

  def make_player(class_id: "fighter", level: 1)
    Player.create!(
      name: "Hero", location: city, character_class: class_id, level: level,
      strength: 14, dexterity: 12, constitution: 14,
      intelligence: 10, wisdom: 10, charisma: 10,
      max_hp: 11, current_hp: 11, xp: 0,
      abilities: []
    )
  end

  describe ".run" do
    it "presents eligible abilities and appends the chosen one (stamped with uses_remaining)" do
      player = make_player(class_id: "fighter", level: 1)
      io  = StringIO.new("1\n")
      out = StringIO.new
      described_class.run(player, count: 1, io: io, out: out, logger: logger)

      player.reload
      expect(player.abilities.size).to eq(1)
      a = player.abilities.first
      expect(a["uses_remaining"]).to eq(a["uses_per_rest"])
      # Listing surfaced at least one ability and prompted for a pick.
      expect(out.string).to match(/Available abilities/)
      expect(out.string).to match(/learned/)
    end

    it "picks `count` distinct abilities, never duplicating an owned id" do
      player = make_player(class_id: "fighter", level: 5)
      io = StringIO.new("1\n1\n1\n")  # always pick option 1 — but options shift each round
      out = StringIO.new
      described_class.run(player, count: 3, io: io, out: out, logger: logger)

      ids = player.reload.abilities.map { |a| a["id"] }
      expect(ids.size).to eq(3)
      expect(ids.uniq.size).to eq(3)
    end

    it "is a no-op for non-Player characters (NPCs use Assigner instead)" do
      npc = Npc.create!(name: "Goon", location: city, character_class: "fighter", level: 3)
      io  = StringIO.new("1\n")
      out = StringIO.new
      result = described_class.run(npc, count: 1, io: io, out: out, logger: logger)
      expect(result).to eq(npc)
      expect(npc.reload.abilities).to be_nil.or eq([])
    end

    it "re-prompts on bad input" do
      player = make_player(class_id: "fighter", level: 1)
      io  = StringIO.new("not a number\n999\n1\n")
      out = StringIO.new
      described_class.run(player, count: 1, io: io, out: out, logger: logger)
      expect(player.reload.abilities.size).to eq(1)
      expect(out.string.scan("! enter a number").size).to eq(2)
    end

    it "exits gracefully when eligible pool is exhausted mid-run" do
      # Commoner pool is small. Set count higher than the pool size; should
      # pick what's available and stop.
      player = make_player(class_id: "commoner", level: 1)
      pool_size = Harness::Abilities::Library.for_class("commoner", max_level: 1).size
      input = ("1\n" * (pool_size + 2))
      io  = StringIO.new(input)
      out = StringIO.new
      picked = described_class.run(player, count: pool_size + 2, io: io, out: out, logger: logger)
      expect(picked).to eq(pool_size)
    end

    it "surfaces a [LOCKED stat] label for abilities with an explicit stat override" do
      player = make_player(class_id: "cleric", level: 1)
      io  = StringIO.new("1\n")
      out = StringIO.new
      described_class.run(player, count: 1, io: io, out: out, logger: logger)
      # cleric's L1 picks include charm_word (CHA-locked) and divine abilities (WIS-locked).
      expect(out.string).to match(/\[LOCKED stat:/)
    end
  end

  describe ".drain_pending!" do
    it "fires the picker for as many slots as pending_ability_picks, then clears the counter" do
      player = make_player(class_id: "fighter", level: 1)
      player.update!(properties: { "pending_ability_picks" => 2 })
      io  = StringIO.new("1\n1\n")
      out = StringIO.new
      picked = described_class.drain_pending!(player, io: io, out: out, logger: logger)
      expect(picked).to eq(2)
      player.reload
      expect(player.abilities.size).to eq(2)
      expect(player.properties).not_to have_key("pending_ability_picks")
    end

    it "no-op when pending counter is zero or missing" do
      player = make_player(class_id: "fighter", level: 1)
      io  = StringIO.new
      out = StringIO.new
      picked = described_class.drain_pending!(player, io: io, out: out, logger: logger)
      expect(picked).to eq(0)
      expect(out.string).to eq("")
    end

    it "no-op for non-Player characters" do
      npc = Npc.create!(name: "Goon", location: city, character_class: "fighter", level: 3,
                        properties: { "pending_ability_picks" => 5 })
      io  = StringIO.new
      out = StringIO.new
      picked = described_class.drain_pending!(npc, io: io, out: out, logger: logger)
      expect(picked).to eq(0)
    end
  end
end
