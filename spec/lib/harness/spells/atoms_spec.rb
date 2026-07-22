require "rails_helper"

RSpec.describe Harness::Spells::Atoms do
  def valid_block
    [
      { "kind" => "damage", "who" => "target", "dice" => "2d6" },
      { "kind" => "heal", "who" => "caster", "dice" => "1d8+2" },
      { "kind" => "timed_effect", "who" => "caster", "name" => "Ward", "duration_minutes" => 30, "roll_modifier" => 2 },
      { "kind" => "mutate_character", "who" => "target", "field" => "charisma", "value" => 18 },
      { "kind" => "coins", "who" => "caster", "delta" => -50 },
      { "kind" => "write_knowledge", "content" => "the well water heals" },
      { "kind" => "create_character", "subrole" => "wolf", "description" => "a grey shape from the treeline", "follow" => true },
      { "kind" => "teleport", "who" => "caster", "destination" => "Saltmere" }
    ]
  end

  it "accepts a block exercising most of the vocabulary" do
    expect(described_class.validate(valid_block)).to eq([])
  end

  it "rejects empty, oversized, and unknown-kind blocks" do
    expect(described_class.validate([])).to be_any
    expect(described_class.validate(valid_block + [ valid_block.first ])).to include(/too many atoms/)
    expect(described_class.validate([ { "kind" => "summon_demon" } ])).to include(/unknown kind/)
  end

  it "rejects missing required fields and bad who refs" do
    expect(described_class.validate([ { "kind" => "damage", "who" => "target" } ])).to include(/missing "dice"/)
    expect(described_class.validate([ { "kind" => "damage", "who" => "the bandit", "dice" => "1d6" } ])).to include(/who must be caster or target/)
  end

  it "enforces crash ceilings, not balance" do
    # 20d100 is absurd but legal; 21 dice or 999 sides is a ceiling breach.
    expect(described_class.validate([ { "kind" => "damage", "who" => "target", "dice" => "20d100" } ])).to eq([])
    expect(described_class.validate([ { "kind" => "damage", "who" => "target", "dice" => "21d6" } ])).to include(/dice count/)
    expect(described_class.validate([ { "kind" => "damage", "who" => "target", "dice" => "1d999" } ])).to include(/sides/)
    expect(described_class.validate([ { "kind" => "damage", "who" => "target", "dice" => "fireball" } ])).to include(/bad dice formula/)
    expect(described_class.validate([ { "kind" => "coins", "who" => "caster", "delta" => 999_999 } ])).to include(/within/)
    expect(described_class.validate([ { "kind" => "advance_clock", "minutes" => 999_999_999 } ])).to include(/minutes/)
    expect(described_class.validate([ { "kind" => "timed_effect", "who" => "caster", "name" => "Ward", "duration_minutes" => 999_999_999, "roll_modifier" => 1 } ])).to include(/duration/)
  end

  it "requires timed_effect to carry something mechanical" do
    expect(described_class.validate([ { "kind" => "timed_effect", "who" => "caster", "name" => "Vague Shimmer" } ]))
      .to include(/needs roll_modifier, modifiers, or effects/)
  end
end
