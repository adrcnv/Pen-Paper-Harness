require "rails_helper"

RSpec.describe Harness::Runners::Dice do
  let(:yard)    { Location.create!(name: "Training Yard") }
  let!(:player) { Player.create!(name: "Hero", location: yard, strength: 14, dexterity: 12) }
  let!(:thug)   { Npc.create!(name: "Thug", subrole: "bandit", location: yard, strength: 12) }
  let(:step)    { Harness::Dispatcher::Step.new(runner: "dice", intent: "climb the wall", args: {}) }

  def context_with(&block)
    Harness::Turn::Context.new(player_location: yard, llm_nuance: StubLLM.new(&block), game_time: 100)
  end

  it "resolves a stat check" do
    ctx = context_with do
      { "actor_id" => player.id, "stat" => "strength", "ability_name" => nil,
        "action" => "climb the wall", "target_id" => nil, "difficulty" => "moderate",
        "time_minutes" => 2, "roll_modifier" => nil, "npc_reaction" => nil }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "climb the wall", step: step)
    expect(outcome.status).to eq(:ok)
    rc = outcome.tool_calls.find { |t| t["name"] == "resolve" }
    expect(rc).to be_present
    expect(rc.dig("result", "outcome")).to be_present # dice actually rolled
  end

  it "commits an NPC counter as a second resolve for a hostile beat" do
    ctx = context_with do
      { "actor_id" => player.id, "stat" => "strength", "action" => "shove the thug",
        "target_id" => thug.id, "time_minutes" => 1,
        "npc_reaction" => { "actor_id" => thug.id, "kind" => "counter", "ability_name" => nil, "prose" => "shoves back" } }.to_json
    end
    scene = Harness::Tools::QueryScene.build(ctx)

    outcome = described_class.new.run(context: ctx, scene: scene, input: "shove the thug", step: step)
    expect(outcome.tool_calls.count { |t| t["name"] == "resolve" }).to eq(2) # player + counter
  end

  it "re-dispatches when no stat or ability is given" do
    ctx = context_with { { "action" => "do a thing", "time_minutes" => 1 }.to_json }
    scene = Harness::Tools::QueryScene.build(ctx)
    outcome = described_class.new.run(context: ctx, scene: scene, input: "do a thing", step: step)
    expect(outcome.status).to eq(:redispatch)
  end

  # Regression: the player healed an ambient "recruit" who was only ever a
  # present_extras string — the dice runner resolved with no target (self-cast)
  # and the recruit never became a character. Now an extra target promotes.
  describe "promoting an extra target" do
    let(:recruit_desc) { "a young recruit shivering by the hearth, trying to dry his socks" }

    def context_targeting_extra
      ctx = Harness::Turn::Context.new(
        player_location: yard,
        llm_nuance: StubLLM.new {
          { "actor_id" => player.id, "ability_name" => nil, "stat" => "wisdom",
            "action" => "mend the recruit's hand", "target_id" => nil,
            "target_extra_index" => 0, "target_subrole" => "recruit",
            "difficulty" => "moderate", "time_minutes" => 2 }.to_json
        },
        game_time: 100
      )
      ctx.active_scene = Harness::Scene::Active.new(
        location: yard,
        snapshot: Harness::Scene::Assembler.for(location: yard),
        extras: [ recruit_desc ]
      )
      ctx
    end

    it "materializes the extra into a real Npc and targets it" do
      ctx = context_targeting_extra
      scene = Harness::Tools::QueryScene.build(ctx)

      expect {
        @outcome = described_class.new.run(context: ctx, scene: scene, input: "cast mending light on the recruit's finger", step: step)
      }.to change(Npc, :count).by(1)

      pc = @outcome.tool_calls.find { |t| t["name"] == "propose_character" }
      expect(pc.dig("args", "from_extra")).to eq(recruit_desc)
      new_id = pc.dig("result", "character_id")
      expect(new_id).to be_present

      rc = @outcome.tool_calls.find { |t| t["name"] == "resolve" }
      expect(rc.dig("args", "target_id")).to eq(new_id) # healed the recruit, not nil/self
    end

    it "consumes the extra and refreshes the scene so narration sees the new character" do
      ctx = context_targeting_extra
      scene = Harness::Tools::QueryScene.build(ctx)
      outcome = described_class.new.run(context: ctx, scene: scene, input: "heal the recruit", step: step)
      new_id = outcome.tool_calls.find { |t| t["name"] == "propose_character" }.dig("result", "character_id")

      expect(ctx.active_scene.present_extras).not_to include(recruit_desc)
      expect(ctx.active_scene.present_characters.map(&:id)).to include(new_id)
    end
  end
end
