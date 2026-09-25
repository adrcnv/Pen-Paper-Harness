require "rails_helper"

RSpec.describe Harness::Settlement::Doctrine do
  let(:town) do
    Location.create!(name: "Saltmere", x: 10.0, y: 20.0, biome: "lowland",
                     properties: { "kind" => "city", "terrain" => "coastal", "coastal" => true,
                                   "economic_basis" => "fishing", "size" => "town", "wealth" => "modest" })
  end
  let!(:rooms)  { Harness::Settlement::Layout.lay_out!(city: town, rng: Random.new(1)) }
  let(:tavern)  { rooms.find { |r| r.properties["manifest_key"] == "tavern" } }
  let(:smithy)  { rooms.find { |r| r.properties["manifest_key"] == "smithy" } }
  let(:hall)    { rooms.find { |r| r.properties["trade"] == "reeve" } }
  let!(:eir)    { Npc.create!(name: "Eir Leifson", subrole: "barkeep", location: tavern, home_location_id: tavern.id, current_hp: 5, max_hp: 5) }
  let(:llm)     { StubLLM.new { |_p| { "personality" => "stern", "appearance" => "Grey, upright." }.to_json } }

  def facts     = Knowledge.current.where(source_kind: "layout", location_id: town.id).order(:id).to_a
  def town_rows = Knowledge.where(source_kind: "layout", location_id: town.id)
  def texts     = facts.map(&:content)

  it "writes one local fact per office from rows — keeper by name once seeded — and one per civic office the town lacks" do
    Npc.create!(name: "Sleeping Priest", subrole: "priest", location: town, home_location_id: town.id, current_hp: 5, max_hp: 5, properties: { "dormant" => true })
    rows = described_class.refresh!(tavern, game_time: 100)
    expect(rows).to match_array(facts)
    expect(facts.map(&:location_id).uniq).to eq([ town.id ])
    expect(texts).to include("Saltmere's barkeep is Eir Leifson, at #{tavern.name}.")   # the keeper by name
    expect(texts).to include("Saltmere's smith is at #{smithy.name}.")                    # the room stands, the keeper comes on entry
    absent = texts.grep(/\ASaltmere has no /)
    expect(absent).to match_array([ "Saltmere has no moneylender.", "Saltmere has no tanner.", "Saltmere has no miller." ])   # a modest fishing town: no counting-house, tannery or mill; the moot hall, shrine and smithy stand
    expect(texts).not_to include("Saltmere has no priest.")    # the shrine stands even though its priest sleeps
  end

  it "carries the keeper's name from the start once keepers are named at layout" do
    Harness::Scene::StaffSeeder.name_all!(town, rng: Random.new(1))
    described_class.refresh!(town)
    expect(texts).to include(match(/\ASaltmere's smith is [[:upper:]][^,]+, at #{Regexp.escape(smithy.name)}\.\z/))
    expect(texts).not_to include("Saltmere's smith is at #{smithy.name}.")
  end

  it "names a resident who holds a civic office no room carries" do
    Npc.create!(name: "Wynflaed", subrole: "moneylender", location: town, home_location_id: town.id, current_hp: 5, max_hp: 5)
    described_class.refresh!(town)
    expect(texts).to include("Saltmere's moneylender is Wynflaed.")
    expect(texts).not_to include("Saltmere has no moneylender.")
  end

  it "is idempotent while nothing changed, and revises only the office that changed when a keeper appears" do
    first = described_class.refresh!(town)
    expect { described_class.refresh!(smithy) }.not_to change(town_rows, :count)

    Npc.create!(name: "Hengist", subrole: "smith", location: smithy, home_location_id: smithy.id, current_hp: 5, max_hp: 5)
    second = described_class.refresh!(smithy, game_time: 500)
    expect(second.size).to eq(first.size)
    expect(texts).to include("Saltmere's smith is Hengist, at #{smithy.name}.")
    expect(texts).not_to include("Saltmere's smith is at #{smithy.name}.")
    expect((first - second).map(&:content)).to eq([ "Saltmere's smith is at #{smithy.name}." ])   # only that row retired
    expect(town_rows.where(current: false).count).to eq(1)
  end

  it "lets a reflection's revision of a row stand while the rows behind it hold, and retires it when they change" do
    described_class.refresh!(town)
    old = facts.find { |k| k.content == "Saltmere's smith is at #{smithy.name}." }
    revision = Knowledge.create!(content: "#{old.content} He shoes the carters' horses.", location_id: town.id, current: true,
                                 source_kind: "conversation", supersedes_id: old.id)
    old.update!(current: false)

    expect { described_class.refresh!(tavern) }.not_to change(town_rows, :count)
    expect(revision.reload.current).to be(true)

    Npc.create!(name: "Hengist", subrole: "smith", location: smithy, home_location_id: smithy.id, current_hp: 5, max_hp: 5)
    described_class.refresh!(smithy)
    expect(revision.reload.current).to be(false)
    expect(texts).to include("Saltmere's smith is Hengist, at #{smithy.name}.")
  end

  it "reaches every room of the town through the knowledge query, and never the next town" do
    described_class.refresh!(town)
    expect(Harness::Knowledge::Query.candidates_for(eir)).to include(*facts)
    far = Location.create!(name: "Coldleigh", x: 50.0, y: 50.0)
    stranger = Npc.create!(name: "Osric", subrole: "reeve", location: far, home_location_id: far.id, current_hp: 5, max_hp: 5)
    expect(Harness::Knowledge::Query.candidates_for(stranger)).not_to include(*facts)
  end

  it "writes nothing for the wilderness" do
    leaf = Location.create!(name: "Bend", properties: { "kind" => "wilderness_leaf" })
    expect(described_class.refresh!(leaf)).to be_nil
    expect(Knowledge.where(source_kind: "layout", location_id: leaf.id)).to be_empty
  end

  describe ".holder (the offices half of the person door, on exact trades)" do
    it "links the keeper of the room a claim anchors to, whatever the trade" do
      held = described_class.holder("barkeep", smithy, anchor: tavern)
      expect(held).to be_linked
      expect(held.npc).to eq(eir)
      expect(held.words).to eq("barkeep")
    end

    it "seeds a civic room's keeper when the player has not been in yet, once — and says reeve or magistrate" do
      expect(hall).to be_present
      held = described_class.holder("reeve", tavern, llm: llm)
      expect(held).to be_linked
      expect(held.npc.subrole).to eq("reeve")
      expect(held.npc.home_location_id).to eq(hall.id)
      expect(held.words).to eq("reeve or magistrate")
      expect(described_class.holder("reeve", tavern, llm: llm).npc).to eq(held.npc)
    end

    it "links a resident who holds a civic office no room carries" do
      wyn = Npc.create!(name: "Wynflaed", subrole: "moneylender", location: town, home_location_id: town.id, current_hp: 5, max_hp: 5)
      expect(described_class.holder("moneylender", tavern).npc).to eq(wyn)
    end

    it "refuses a civic office the town lacks" do
      held = described_class.holder("moneylender", tavern)
      expect(held).to be_absent
      expect(held.words).to eq("moneylender")
    end

    it "has no opinion on a trade that is no civic office, nor on a crew's — a carter, a peat cutter, a guard" do
      expect(described_class.holder("carter", tavern)).to be_nil
      expect(described_class.holder("peat_cutter", tavern)).to be_nil
      expect(described_class.holder("guard", tavern)).to be_nil
      expect(described_class.holder("", tavern)).to be_nil
    end
  end

  describe ".office_held? (one holder per unique office)" do
    it "is true for an office a keeper or a resident holds, false for one nobody holds, false for a crew's trade and for mere trades" do
      expect(described_class.office_held?("barkeep", smithy)).to be(true)
      expect(described_class.office_held?("reeve", smithy)).to be(false)
      described_class.holder("reeve", tavern, llm: llm)
      expect(described_class.office_held?("reeve", smithy)).to be(true)
      Npc.create!(name: "Sergeant", subrole: "guard", location: town, home_location_id: town.id, current_hp: 5, max_hp: 5)
      expect(described_class.office_held?("guard", smithy)).to be(false)
      expect(described_class.office_held?("fisher", smithy)).to be(false)
    end
  end
end
