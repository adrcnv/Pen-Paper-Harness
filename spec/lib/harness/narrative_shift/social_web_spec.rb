require "rails_helper"

RSpec.describe Harness::NarrativeShift::SocialWeb do
  let(:relay)   { Location.create!(name: "Blackwood Relay") }
  let!(:player) { Player.create!(name: "Hero", location: relay) }
  let(:ctx)     { Harness::Turn::Context.new(player_location: relay, game_time: 200) }

  # A placed claimed person awaiting their social web.
  def claimed(name, gist: "the relay contact awaiting the courier")
    Npc.create!(name: name, subrole: "contact", location: relay,
                properties: { "claim_pending_web" => true, "claim_gist" => gist })
  end

  def resident(name)
    Npc.create!(name: name, subrole: "keeper", location: relay)
  end

  it "ties a claimed person to up to two present residents via local awareness events" do
    harek = claimed("Harek")
    k1 = resident("Bram")
    k2 = resident("Tess")
    resident("Odd") # a third — only two should be wired

    expect { described_class.weave!([ harek, k1, k2, Npc.last ], ctx) }.to change(Event, :count).by(2)

    # Each awareness event ties a knower to Harek as subject, scope local.
    evs = Event.where(scope: "local").select { |e| e.details.dig("narrative", "trigger") == "knows Harek" }
    expect(evs.size).to eq(2)
    knower_ids = evs.flat_map { |e| e.event_participants.where(role: "knower").pluck(:character_id) }
    expect(knower_ids).to all(be_in([ k1.id, k2.id, Npc.last.id ]))
  end

  it "clears the pending flag once woven (idempotent)" do
    harek = claimed("Harek")
    resident("Bram")
    present = [ harek, Npc.find_by(name: "Bram") ]

    described_class.weave!(present, ctx)
    expect(harek.reload.properties["claim_pending_web"]).to be_nil
    # Second pass: flag gone → no new events.
    expect { described_class.weave!([ harek.reload, Npc.find_by(name: "Bram") ], ctx) }.not_to change(Event, :count)
  end

  it "defers (keeps the flag) when the claimed person is alone" do
    harek = claimed("Harek")
    expect { described_class.weave!([ harek ], ctx) }.not_to change(Event, :count)
    expect(harek.reload.properties["claim_pending_web"]).to be(true)
  end

  it "carries the claim gist into the awareness prose (no re-invention)" do
    harek = claimed("Harek", gist: "the smuggler who owes Vesna a debt")
    resident("Bram")
    described_class.weave!([ harek, Npc.find_by(name: "Bram") ], ctx)
    ev = Event.where(scope: "local").last
    expect(ev.details.dig("narrative", "details")).to include("the smuggler who owes Vesna a debt")
  end

  it "prefers grounded residents over wiring two fresh claims together" do
    harek = claimed("Harek")
    doran = claimed("Doran")
    bram  = resident("Bram")
    described_class.weave!([ harek, doran, bram ], ctx)
    # Harek should be known by the grounded resident Bram, not by the other claim.
    ev = Event.where(scope: "local").find { |e| e.details.dig("narrative", "trigger") == "knows Harek" }
    knower_ids = ev.event_participants.where(role: "knower").pluck(:character_id)
    expect(knower_ids).to eq([ bram.id ])
  end
end
