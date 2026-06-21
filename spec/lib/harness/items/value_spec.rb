require "rails_helper"

RSpec.describe Harness::Items::Value do
  def item(tags: [], modifiers: [], effects: [])
    Item.new(name: "x", subrole: "t", location_id: 1,
             properties: { "tags" => tags, "modifiers" => modifiers, "effects" => effects })
  end

  it "values a plain weapon above bare base, a plain ring higher still" do
    plain_weapon = described_class.of(item(tags: %w[weapon edged]))
    plain_ring   = described_class.of(item(tags: %w[jewelry ring]))
    expect(plain_weapon).to be > described_class::BASE
    expect(plain_ring).to be > plain_weapon
  end

  it "values power, not the name — stat modifiers raise worth" do
    plain  = described_class.of(item(tags: %w[weapon], modifiers: []))
    strong = described_class.of(item(tags: %w[weapon], modifiers: [ { "stat" => "strength", "op" => "add", "value" => 3 } ]))
    expect(strong).to eq(plain + 3 * described_class::STAT_PER_POINT)
  end

  it "counts a bonus damage die" do
    base = described_class.of(item(tags: %w[weapon]))
    dmg  = described_class.of(item(tags: %w[weapon], modifiers: [ { "damage_dice" => "1d4", "op" => "add", "on" => "attack" } ]))
    expect(dmg).to eq(base + described_class::DAMAGE_MODIFIER)
  end

  it "an effect dominates the price (rare/powerful)" do
    mundane = described_class.of(item(tags: %w[jewelry]))
    magical = described_class.of(item(tags: %w[jewelry magical], effects: [ { "trigger" => "death_save", "params" => {} } ]))
    expect(magical).to be >= mundane + described_class::EFFECT_BONUS
  end

  it "never returns below 1" do
    expect(described_class.of(item(tags: []))).to be >= 1
  end
end
