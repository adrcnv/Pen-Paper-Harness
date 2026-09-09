require "rails_helper"

RSpec.describe Harness::Combat::FightCapable do
  it "lets guards and road bandits draw steel, never a cook" do
    expect(described_class.fight_capable?(Npc.new(subrole: "guard"))).to be(true)
    expect(described_class.fight_capable?(Npc.new(subrole: "Highwayman"))).to be(true)
    expect(described_class.fight_capable?(Npc.new(subrole: "cook"))).to be(false)
    expect(described_class.fight_capable?(nil)).to be(false)
  end
end
