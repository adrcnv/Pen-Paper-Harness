require "rails_helper"
require "tmpdir"

RSpec.describe Harness::Debug::Replay do
  let(:city)    { Location.create!(name: "Saltmere") }
  let!(:player) { Player.create!(name: "Hero", location: city) }
  let(:context) { Harness::Turn::Context.new(player_location: city) }
  let(:manager) { Harness::Scene::Manager.new(context: context) }

  def rewind(dir)
    described_class.rewind!(context: context, scene_manager: manager, snapshot_dir: dir)
  end

  it "refuses to rewind when no turns have run" do
    expect { rewind("/tmp/nowhere") }.to raise_error(described_class::Error, /no turns/)
  end

  it "refuses to rewind when the previous turn's snapshot file is missing" do
    TurnLog.create!(turn_number: 5, input: "attack the miller")
    Dir.mktmpdir do |dir|
      expect { rewind(dir) }.to raise_error(described_class::Error, /no snapshot for turn 4/)
    end
  end

  it "wiring_stamp carries a prompt hash (the staleness tripwire)" do
    stamp = described_class.wiring_stamp
    expect(stamp[:prompt_hash]).to match(/\A[0-9a-f]{12}\z/)
  end

  describe "stamp_drift_notices" do
    it "warns loudly on code drift, quietly notes prompt drift" do
      live = described_class.wiring_stamp
      SessionState.create!(git_sha: "deadbee", prompt_hash: "0" * 12)
      notices = described_class.stamp_drift_notices
      expect(notices.join).to include("restored objects may not match current code") if live[:git_sha]
      expect(notices.join).to include("prompts changed since this snapshot")
    end

    it "is silent when stamps match" do
      live = described_class.wiring_stamp
      SessionState.create!(git_sha: live[:git_sha], prompt_hash: live[:prompt_hash])
      expect(described_class.stamp_drift_notices).to be_empty
    end
  end

  describe "rehydrate!" do
    it "rebuilds context and scene buffer from the session_states row without the enter chain" do
      tavern = Location.create!(name: "Tavern", parent: city)
      player.update!(location: tavern)
      scene = Harness::Scene::Serializer.dump(
        Harness::Scene::Active.new(
          location: tavern, snapshot: Harness::Scene::Assembler.for(location: tavern),
          narrations: [ { "input" => "hi", "narration" => "dim room" } ],
          internal_state: {}, agendas: {}, extras: [], entered_at_game_time: 90
        )
      )
      SessionState.create!(location_id: tavern.id, scene: scene, history: [ { "input" => "hi", "narration" => "dim room" } ], game_time: 12_345)

      described_class.rehydrate!(context: context, scene_manager: manager)

      expect(context.player_location).to eq(tavern)
      expect(context.game_time).to eq(12_345)
      expect(context.history.size).to eq(1)
      expect(manager.active).not_to be_nil
      expect(manager.active.location).to eq(tavern)
      expect(manager.active.narrations.size).to eq(1)
    end
  end
end
