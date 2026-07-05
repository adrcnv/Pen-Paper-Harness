require "rails_helper"

RSpec.describe Harness::Knowledge::Capture do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }
  let(:default_lines) { [ { "speaker" => "Tomas", "says" => "They say the salt tithe was repealed last winter." } ] }

  def capture(response, location: tavern, lines: default_lines, game_time: 100, context: nil)
    llm = StubLLM.new { |_p| response.is_a?(String) ? response : response.to_json }
    described_class.run(llm: llm, location: location, lines: lines, game_time: game_time, context: context)
  end

  def facts(*fs) = { "facts" => fs }

  def ctx = Harness::Turn::Context.new(player_location: tavern, game_time: 100, llm_grunt: StubLLM.new { "{}" })

  describe "writing" do
    it "writes a storable fact with its facets" do
      out = capture(facts("content" => "The salt tithe was repealed last winter.", "subrole" => nil, "scope" => "local", "min_int" => nil))
      expect(out.size).to eq(1)
      k = Knowledge.last
      expect(k.content).to eq("The salt tithe was repealed last winter.")
      expect(k.source_kind).to eq("conversation")
      expect(k.game_time).to eq(100)
      expect(k.current).to be(true)
    end

    it "anchors a LOCAL fact at the root settlement (town-wide via the up-chain)" do
      capture(facts("content" => "x", "scope" => "local"))
      expect(Knowledge.last.location_id).to eq(city.id) # root, not the tavern sublocation
    end

    it "leaves a WORLD fact unscoped (null location)" do
      capture(facts("content" => "x", "scope" => "world"))
      expect(Knowledge.last.location_id).to be_nil
    end

    it "keeps an exact-vocabulary subrole" do
      capture(facts("content" => "clerk lore", "subrole" => "clerk"))
      expect(Knowledge.last.subrole).to eq("clerk")
    end

    it "nulls a non-vocabulary subrole but still writes the fact" do
      capture(facts("content" => "some fact", "subrole" => "patron"))
      k = Knowledge.last
      expect(k.content).to eq("some fact")
      expect(k.subrole).to be_nil
    end

    it "embeds and stores a vector for a written knowledge fact when the client can embed" do
      llm = StubLLM.new { |_p| { "facts" => [ { "content" => "clerk lore", "subrole" => "clerk" } ] }.to_json }
      llm.define_singleton_method(:embed) { |texts| Array(texts).map { [ 0.5, 0.5 ] } }
      described_class.run(llm: llm, location: tavern, lines: default_lines, game_time: 100)
      expect(JSON.parse(Knowledge.last.embedding)).to eq([ 0.5, 0.5 ])
    end

    it "passes an integer min_int through and ignores a non-integer" do
      capture(facts({ "content" => "learned", "min_int" => 12 }, { "content" => "plain", "min_int" => "high" }))
      expect(Knowledge.find_by(content: "learned").min_int).to eq(12)
      expect(Knowledge.find_by(content: "plain").min_int).to be_nil
    end
  end

  describe "participation routing (concerns)" do
    it "routes a fact about a named party to a personal-scope event, not knowledge" do
      ingvar = Npc.create!(name: "Ingvar Ingvarson", location: city)
      expect {
        capture(facts("content" => "Ingvar owes the counting house forty marks.", "concerns" => [ "Ingvar Ingvarson" ]))
      }.to change(Event, :count).by(1)
      expect(Knowledge.count).to eq(0)

      ev = Event.last
      expect(ev.scope).to eq("personal")
      expect(ev.participants).to include(ingvar)
      expect(ev.details.dig("narrative", "details")).to match(/forty marks/)
    end

    it "resolves a party by first-token and keeps unresolved names as prose" do
      ingvar = Npc.create!(name: "Ingvar Ingvarson", location: city)
      capture(facts("content" => "Ingvar and Bo settled up.", "concerns" => [ "Ingvar", "Bo the Unknown" ]))
      ev = Event.last
      expect(ev.participants).to eq([ ingvar ])
      expect(ev.details["concerns_unresolved"]).to eq([ "Bo the Unknown" ])
    end

    it "skips (defers to realizer) a participation fact when no party exists" do
      capture(facts("content" => "Cwenild keeps the hiring ledger.", "concerns" => [ "Cwenild" ]))
      expect(Event.count).to eq(0)
      expect(Knowledge.count).to eq(0)
    end

    it "does not double-write the same participation fact for the same party" do
      Npc.create!(name: "Ingvar Ingvarson", location: city)
      capture(facts("content" => "Ingvar owes forty marks.", "concerns" => [ "Ingvar Ingvarson" ]))
      expect {
        capture(facts("content" => "ingvar owes forty marks.", "concerns" => [ "Ingvar Ingvarson" ]))
      }.not_to change(Event, :count)
    end
  end

  describe "person fact inheritance (minted map)" do
    # A fact naming a person realized THIS turn must attach to their row, even
    # when that person lives outside the current settlement — the settlement-scope
    # lookup would miss them; the minted map catches them.
    it "attaches a participation fact to a person linked this turn" do
      elsewhere = Location.create!(name: "Redmarsh")               # NOT under `city`
      harek     = Npc.create!(name: "Harek", subrole: "ferryman", location: elsewhere)

      payload = {
        "people" => [ { "name" => "Harek", "subrole" => "ferryman", "by" => "Tomas" } ],
        "facts"  => [ { "content" => "Harek owes the counting house forty marks.", "concerns" => [ "Harek" ] } ]
      }
      expect {
        capture(payload, context: ctx)
      }.to change(Event, :count).by(1)

      expect(Event.last.participants).to include(harek)
    end

    it "still skips a fact naming a person nobody realized (no minting, no scope)" do
      payload = {
        "people" => [],
        "facts"  => [ { "content" => "Cwenild keeps the ledger.", "concerns" => [ "Cwenild" ] } ]
      }
      expect { capture(payload, context: ctx) }.not_to change(Event, :count)
    end
  end

  describe "place realization (wiring)" do
    it "mints a proper-named place named in dialogue" do
      payload = { "facts" => [], "places" => [ { "name" => "The Salt Wharf", "about" => "the loading docks" } ] }
      expect {
        capture(payload, context: ctx)
      }.to change { Location.where(name: "The Salt Wharf").count }.by(1)
      expect(Location.find_by(name: "The Salt Wharf").parent).to eq(city)
    end

    it "does not mint places without a context (unit path)" do
      tavern # force fixtures before measuring
      payload = { "facts" => [], "places" => [ { "name" => "The Salt Wharf" } ] }
      expect { capture(payload) }.not_to change(Location, :count)
    end
  end

  describe "dedup" do
    it "does not write a duplicate (same facets + case-insensitive content)" do
      capture(facts("content" => "The harbor closes at dusk.", "scope" => "local"))
      expect {
        capture(facts("content" => "the harbor closes at dusk.", "scope" => "local"))
      }.not_to change(Knowledge, :count)
    end

    it "DOES write when the same content lands under different facets" do
      capture(facts("content" => "The gate is watched.", "scope" => "local"))
      expect {
        capture(facts("content" => "The gate is watched.", "scope" => "world"))
      }.to change(Knowledge, :count).by(1)
    end
  end

  describe "revision (modification plumbing)" do
    # A standing town fact the conversation keeps elaborating. Embedded so the
    # cosine scan can score it.
    let!(:standing) do
      Knowledge.create!(
        content: "The town's founder drowned in the fog near an abandoned hut.",
        location_id: city.id, min_int: 9, current: true,
        source_kind: "conversation", game_time: 50,
        embedding: JSON.generate([ 1.0, 0.0 ])
      )
    end

    # Extraction call returns one local fact; the merge-judge call (recognized
    # by its distinct prompt) returns `verdict`. Embeds map any text to the
    # same vector as the standing row → cosine 1.0 → the judge always fires.
    def capture_revision(verdict, fact_content: "The founder was named Elara.", embed_vec: [ 1.0, 0.0 ])
      llm = StubLLM.new do |p|
        if p.include?("STANDING fact")
          verdict.to_json
        else
          { "facts" => [ { "content" => fact_content, "scope" => "local" } ] }.to_json
        end
      end
      llm.define_singleton_method(:embed) { |texts| Array(texts).map { embed_vec } }
      described_class.run(llm: llm, location: tavern, lines: default_lines, game_time: 100)
    end

    it "EXTENDS: supersedes the standing row with the merged fact, facets inherited verbatim" do
      merged = "The town's founder, Elara, drowned in the fog near her abandoned hut."
      out = capture_revision({ "relation" => "extends", "merged" => merged })

      expect(standing.reload.current).to be(false)
      row = Knowledge.find_by(content: merged)
      expect(row.current).to be(true)
      expect(row.supersedes_id).to eq(standing.id)
      expect(row.location_id).to eq(standing.location_id)
      expect(row.min_int).to eq(9)
      expect(row.game_time).to eq(100)
      expect(out).to eq([ row ])
    end

    it "EXTENDS with nothing new (merged == standing) skips as semantic duplicate" do
      expect {
        capture_revision({ "relation" => "extends", "merged" => standing.content.upcase })
      }.not_to change(Knowledge, :count)
      expect(standing.reload.current).to be(true)
    end

    it "CONTRADICTS: keeps the standing fact and writes nothing (denial is stance)" do
      expect {
        capture_revision({ "relation" => "contradicts" }, fact_content: "There was never any founder.")
      }.not_to change(Knowledge, :count)
      expect(standing.reload.current).to be(true)
    end

    it "UNRELATED: writes fresh (cosine false positive, judge is the precision gate)" do
      out = capture_revision({ "relation" => "unrelated" }, fact_content: "The harbor closes at dusk.")
      expect(standing.reload.current).to be(true)
      row = Knowledge.find_by(content: "The harbor closes at dusk.")
      expect(row.supersedes_id).to be_nil
      expect(out).to eq([ row ])
    end

    it "below the cosine floor: no judge call, writes fresh" do
      llm = StubLLM.new do |p|
        raise "judge must not fire" if p.include?("STANDING fact")
        { "facts" => [ { "content" => "The harbor closes at dusk.", "scope" => "local" } ] }.to_json
      end
      llm.define_singleton_method(:embed) { |texts| Array(texts).map { [ 0.0, 1.0 ] } } # orthogonal to standing
      described_class.run(llm: llm, location: tavern, lines: default_lines, game_time: 100)

      expect(standing.reload.current).to be(true)
      expect(Knowledge.find_by(content: "The harbor closes at dusk.")).to be_present
    end

    it "without an embed-capable client the scan is skipped entirely (writes fresh)" do
      out = capture(facts("content" => "The founder was named Elara.", "scope" => "local"))
      expect(standing.reload.current).to be(true)
      expect(out.size).to eq(1)
      expect(out.first.supersedes_id).to be_nil
    end

    it "a superseded row drops out of the recall gate; the merged row surfaces" do
      merged = "The town's founder, Elara, drowned in the fog near her abandoned hut."
      capture_revision({ "relation" => "extends", "merged" => merged })

      npc = Npc.create!(name: "Velora", location: tavern, intelligence: 10)
      contents = Harness::Knowledge::Query.for(character: npc).map(&:content)
      expect(contents).to include(merged)
      expect(contents).not_to include(standing.content)
    end
  end

  describe "non-facts" do
    it "writes nothing for an empty facts list (banter)" do
      expect { capture(facts) }.not_to change(Knowledge, :count)
    end

    it "skips a fact with blank content" do
      expect { capture(facts("content" => "   ")) }.not_to change(Knowledge, :count)
    end

    it "survives unparseable output" do
      expect { capture("not json at all") }.not_to change(Knowledge, :count)
    end
  end

  describe "no lines" do
    it "returns empty and makes NO llm call" do
      llm = StubLLM.new { |_p| raise "should not be called" }
      out = described_class.run(llm: llm, location: tavern, lines: [], game_time: 1)
      expect(out).to eq([])
      expect(llm.user_calls).to be_empty
    end
  end
end
