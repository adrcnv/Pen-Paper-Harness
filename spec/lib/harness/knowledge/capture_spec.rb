require "rails_helper"

RSpec.describe Harness::Knowledge::Capture do
  let(:city)   { Location.create!(name: "Saltmere") }
  let(:tavern) { Location.create!(name: "Tavern", parent: city) }

  # Ingestion-only since the reflection rework: the payload arrives already
  # extracted (the speaker's own reflection output); the llm serves only the
  # revision judge + embeddings.
  def capture(payload, location: tavern, game_time: 100, context: nil, speaker: "Tomas", llm: StubLLM.new { "{}" })
    described_class.ingest(payload: payload, speaker: speaker, llm: llm, location: location, game_time: game_time, context: context)
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
      expect(k.speaker).to eq("Tomas") # provenance — which mouth this came out of
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

    it "nulls the trade facet even when the model supplies one (speaker-POV stamps its own trade)" do
      capture(facts("content" => "clerk lore", "subrole" => "clerk"))
      k = Knowledge.last
      expect(k.content).to eq("clerk lore")
      expect(k.subrole).to be_nil
    end

    it "embeds and stores a vector for a written knowledge fact when the client can embed" do
      llm = StubLLM.new { |_p| "{}" }
      llm.define_singleton_method(:embed) { |texts| Array(texts).map { [ 0.5, 0.5 ] } }
      capture(facts("content" => "clerk lore", "subrole" => "clerk"), llm: llm)
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

    it "adds the speaker as teller when their row exists" do
      tomas  = Npc.create!(name: "Tomas", location: tavern)
      ingvar = Npc.create!(name: "Ingvar Ingvarson", location: city)
      capture(facts("content" => "Ingvar owes forty marks.", "concerns" => [ "Ingvar Ingvarson" ]))
      ev = Event.last
      expect(ev.participants).to contain_exactly(tomas, ingvar)
      expect(ev.event_participants.find_by(character: tomas).role).to eq("teller")
      expect(ev.event_participants.find_by(character: ingvar).role).to eq("subject")
    end
  end

  describe "temporal routing (when)" do
    it "routes a dated happening to a backdated event owned by the teller, no trigger" do
      tomas = Npc.create!(name: "Tomas", location: tavern)
      expect {
        capture(facts("content" => "The mill wheel shattered in the spring flood.", "when" => "3 days ago"),
                game_time: 20_000)
      }.to change(Event, :count).by(1)
      expect(Knowledge.count).to eq(0)

      ev = Event.last
      expect(ev.scope).to eq("personal")
      expect(ev.game_time).to eq(20_000 - 3 * 1_440)
      expect(ev.participants).to eq([ tomas ])
      expect(ev.details.dig("narrative", "trigger")).to be_nil
      expect(ev.details.dig("narrative", "details")).to match(/mill wheel/)
    end

    it "parses word numbers and year-units, clamping at time zero" do
      Npc.create!(name: "Tomas", location: tavern)
      capture(facts("content" => "The old granary burned down.", "when" => "two winters ago"), game_time: 100)
      expect(Event.last.game_time).to eq(0) # 100 - 2 years clamps
    end

    it "parses 'last night' as a dated happening (the wolf-ambush hole: time was silently dropped)" do
      Npc.create!(name: "Tomas", location: tavern)
      expect {
        capture(facts("content" => "A wolf pack took two sheep from the folds.", "when" => "last night"),
                game_time: 20_000)
      }.to change(Event, :count).by(1)
      expect(Knowledge.count).to eq(0)
      expect(Event.last.game_time).to eq(20_000 - 1_440)
    end

    it "parses 'an hour ago' as a dated happening (the crewless-boat hole: 'an hour ago' baked into knowledge)" do
      Npc.create!(name: "Tomas", location: tavern)
      expect {
        capture(facts("content" => "A boat arrived at the docks with no crew.", "when" => "an hour ago"),
                game_time: 20_000)
      }.to change(Event, :count).by(1)
      expect(Knowledge.count).to eq(0)
      expect(Event.last.game_time).to eq(20_000 - 60)
    end

    it "routes a vague past ('many moons ago') to knowledge, wording intact" do
      Npc.create!(name: "Tomas", location: tavern)
      expect {
        capture(facts("content" => "The river shifted its course many moons ago.", "when" => "many moons ago"))
      }.to change(Knowledge, :count).by(1)
      expect(Event.count).to eq(0)
    end

    it "combines when + concerns: teller and party both own the backdated event" do
      tomas  = Npc.create!(name: "Tomas", location: tavern)
      ingvar = Npc.create!(name: "Ingvar Ingvarson", location: city)
      capture(facts("content" => "Ingvar lost his boat in the storm.",
                    "concerns" => [ "Ingvar" ], "when" => "yesterday"), game_time: 20_000)
      ev = Event.last
      expect(ev.game_time).to eq(20_000 - 1_440)
      expect(ev.participants).to contain_exactly(tomas, ingvar)
    end

    it "skips a dated fact when neither teller nor any party resolves" do
      expect {
        capture(facts("content" => "The bridge collapsed.", "when" => "4 days ago"))
      }.not_to change(Event, :count)
      expect(Knowledge.count).to eq(0)
    end
  end

  describe "deals (the obligations writer)" do
    let!(:speaker_row) { Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern) }
    let!(:player)      { Player.create!(name: "Gu", location: tavern) }

    def deals(*ds) = { "deals" => ds }

    it "writes an open obligation between the speaker and the player" do
      capture(deals("who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "coins", "amount" => 5,
                    "terms" => "Five coppers for the ale", "due" => "before you leave town"))
      ob = Obligation.last
      expect(ob.debtor).to eq(player)
      expect(ob.creditor).to eq(speaker_row)
      expect(ob).to have_attributes(kind: "coins", amount: 5, status: "open",
                                    due: "before you leave town", game_time: 100)
    end

    it "resolves a spoken 'where' to an existing location, link-only" do
      capture(deals("who_owes" => "Tomas", "owed_to" => "Gu", "kind" => "meet",
                    "terms" => "Meet in Saltmere at dusk", "due" => "at dusk", "where" => "saltmere"))
      expect(Obligation.last.location_id).to eq(city.id)
    end

    it "falls back to the struck location when 'where' is unknown or absent (never mints)" do
      capture(deals({ "who_owes" => "Tomas", "owed_to" => "Gu", "kind" => "meet",
                      "terms" => "Meet at the Old Bridge", "where" => "the Old Bridge" },
                    { "who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "coins", "amount" => 2,
                      "terms" => "Two coppers for the ale" }))
      expect(Obligation.pluck(:location_id)).to all(eq(tavern.id))
      expect(Location.where("LOWER(name) = ?", "the old bridge")).to be_empty
    end

    describe "machine-tense (a payment executed this turn is history, not a debt)" do
      def ctx_with_transfer(from_id, to_id)
        ctx = Harness::Turn::Context.new(player_location: tavern)
        ctx.turn_transcript = Struct.new(:tool_calls).new(
          [ { "name" => "transfer_coins", "result" => { "from_id" => from_id, "to_id" => to_id, "amount" => 3 } } ]
        )
        ctx
      end

      it "skips a coins deal when the matching transfer already executed this turn" do
        expect {
          capture(deals("who_owes" => "Tomas", "owed_to" => "Gu", "kind" => "coins", "amount" => 3,
                        "terms" => "Three coppers for the sweat"),
                  context: ctx_with_transfer(speaker_row.id, player.id))
        }.not_to change(Obligation, :count)
      end

      it "still mints when the executed transfer was a different pair or direction" do
        expect {
          capture(deals("who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "coins", "amount" => 3,
                        "terms" => "Three coppers for the ale"),
                  context: ctx_with_transfer(speaker_row.id, player.id))
        }.to change(Obligation, :count).by(1)
      end

      it "never suppresses deed deals (only coins have a transfer to match)" do
        expect {
          capture(deals("who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "deed",
                        "terms" => "Haul the stone"),
                  context: ctx_with_transfer(player.id, speaker_row.id))
        }.to change(Obligation, :count).by(1)
      end
    end

    describe "discharged (the settle writer — rows die the way they're born, by the spoken word)" do
      def discharge(*ds) = { "discharged" => ds }

      it "settles an open obligation when the CREDITOR speaks the release" do
        ob = Obligation.create!(debtor: player, creditor: speaker_row, kind: "deed",
                                terms: "Secure the crates", status: "open", game_time: 90)
        capture(discharge("who_owed" => "Gu", "kind" => "deed"))
        expect(ob.reload.status).to eq("settled")
      end

      it "settles the OLDEST open row of that kind between the pair" do
        older = Obligation.create!(debtor: player, creditor: speaker_row, kind: "deed",
                                   terms: "Secure the crates", status: "open", game_time: 80)
        newer = Obligation.create!(debtor: player, creditor: speaker_row, kind: "deed",
                                   terms: "Move the bunks", status: "open", game_time: 90)
        capture(discharge("who_owed" => "Gu", "kind" => "deed"))
        expect(older.reload.status).to eq("settled")
        expect(newer.reload.status).to eq("open")
      end

      it "the DEBTOR claiming it's done releases nothing (only the one owed may settle)" do
        ob = Obligation.create!(debtor: speaker_row, creditor: player, kind: "deed",
                                terms: "Mend the net for Gu", status: "open", game_time: 90)
        capture(discharge("who_owed" => "Tomas", "kind" => "deed"))
        expect(ob.reload.status).to eq("open")
      end

      it "an imagined debt (no matching open row) settles nothing and doesn't raise" do
        ob = Obligation.create!(debtor: player, creditor: speaker_row, kind: "coins", amount: 3,
                                terms: "Three coppers", status: "open", game_time: 90)
        capture(discharge("who_owed" => "Gu", "kind" => "deed"))
        expect(ob.reload.status).to eq("open")
      end

      it "a deal struck and acknowledged done in the same pass settles at birth" do
        capture(deals("who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "deed",
                      "terms" => "Haul the stone").merge(discharge("who_owed" => "Gu", "kind" => "deed")))
        expect(Obligation.last).to have_attributes(kind: "deed", status: "settled")
      end
    end

    it "drops a deal whose parties are not the speaker and the player (hearsay doesn't bind)" do
      expect {
        capture(deals("who_owes" => "Mirek", "owed_to" => "Tomas", "kind" => "deed", "terms" => "Mend the fence"))
      }.not_to change(Obligation, :count)
    end

    it "does not re-strike a same-pair same-kind deal already open (the re-extraction drip)" do
      Obligation.create!(debtor: player, creditor: speaker_row, kind: "coins", amount: 5,
                         terms: "Five for the ale", game_time: 90)
      expect {
        capture(deals("who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "coins", "amount" => 5,
                      "terms" => "Five coppers for the ale"))
      }.not_to change(Obligation, :count)
    end

    it "keeps an unfixed amount as nil (a third of the take)" do
      capture(deals("who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "coins", "amount" => nil,
                    "terms" => "A third of whatever the tip earns"))
      expect(Obligation.last.amount).to be_nil
    end

    it "bakes a parseable due into due_time; a condition-due stays nil" do
      capture(deals({ "who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "meet",
                      "terms" => "Help unload the herring", "due" => "tomorrow dawn" },
                    { "who_owes" => "Tomas", "owed_to" => "Gu", "kind" => "deed",
                      "terms" => "A name for the work", "due" => "after the barge is loaded" }),
              game_time: 480)
      dated, conditional = Obligation.order(:id).last(2)
      expect(dated.due_time).to eq(1440 + 360)
      expect(conditional.due_time).to be_nil
    end

    # The split-brain guard: one reflection pass emitting the same bargain
    # twice — once under `deals` (the ledger: owed) and once under `facts`,
    # usually past tense (history: paid). The obligation owns the happening.
    describe "same-pair fact re-description" do
      def deal_and_fact(fact)
        deals("who_owes" => "Gu", "owed_to" => "Tomas", "kind" => "coins", "amount" => 5,
              "terms" => "Five coppers for the tip").merge(facts(fact))
      end

      it "drops an undated same-pair fact when a deal was struck this pass" do
        expect {
          capture(deal_and_fact("content" => "Gu paid Tomas five coppers for the tip.", "concerns" => [ "Gu" ]))
        }.to change(Obligation, :count).by(1)
        expect(Event.count).to eq(0)
        expect(Knowledge.count).to eq(0)
      end

      it "drops it even when the deal was already on the books (the re-mention drip)" do
        Obligation.create!(debtor: player, creditor: speaker_row, kind: "coins", amount: 5,
                           terms: "Five coppers for the tip", game_time: 90)
        capture(deal_and_fact("content" => "Gu owes Tomas five coppers.", "concerns" => [ "Gu" ]))
        expect(Obligation.count).to eq(1)
        expect(Event.count).to eq(0)
      end

      it "still writes a dated same-pair fact (an explicit when predates the bargain)" do
        expect {
          capture(deal_and_fact("content" => "Gu lodged with Tomas.", "concerns" => [ "Gu" ], "when" => "2 days ago"))
        }.to change(Event, :count).by(1)
      end

      it "drops a concerns-empty fact naming both parties (the knowledge-path leak)" do
        expect {
          capture(deal_and_fact("content" => "Gu and Tomas agreed Gu would pay five coppers for the tip.", "concerns" => []))
        }.to change(Obligation, :count).by(1)
        expect(Knowledge.count).to eq(0)
      end

      it "still writes a concerns-empty fact naming only one party" do
        capture(deal_and_fact("content" => "Tomas keeps the only ledger in Saltmere.", "concerns" => []))
        expect(Knowledge.count).to eq(1)
      end

      it "still writes a fact between a different pair" do
        Npc.create!(name: "Ingvar Ingvarson", location: city)
        expect {
          capture(deal_and_fact("content" => "Ingvar owes the counting house forty marks.", "concerns" => [ "Ingvar Ingvarson" ]))
        }.to change(Event, :count).by(1)
      end
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

  describe "name backflow (the claim learns the minted name)" do
    def stub_realize(name:, id: 999)
      row = Npc.create!(name: name, subrole: "guard", location: tavern)
      allow(Harness::NarrativeShift::Realizer).to receive(:run)
        .and_return({ "character_id" => row.id, "name" => name, "minted" => true })
      row
    end

    it "appends the binding to a fact that mentions the role-reference (the two-Guard-Captains seam)" do
      stub_realize(name: "Mereth Hexham")
      payload = {
        "people" => [ { "name" => "The Guard-Captain", "subrole" => "guard", "gist" => "runs the watch" } ],
        "facts"  => [ { "content" => "The Guard-Captain is occupied with a dispute over a missing ledger.", "concerns" => [] } ]
      }
      capture(payload, context: ctx)
      expect(Knowledge.last.content)
        .to eq("The Guard-Captain is occupied with a dispute over a missing ledger. (The Guard-Captain is Mereth Hexham)")
    end

    it "leaves facts that never mention the reference untouched" do
      stub_realize(name: "Mereth Hexham")
      payload = {
        "people" => [ { "name" => "the harbormaster", "subrole" => "harbormaster", "gist" => "runs the docks" } ],
        "facts"  => [ { "content" => "The salt tithe was repealed last winter.", "concerns" => [] } ]
      }
      capture(payload, context: ctx)
      expect(Knowledge.last.content).to eq("The salt tithe was repealed last winter.")
    end

    it "does not annotate when the realized name matches the spoken reference (proper-name link)" do
      stub_realize(name: "Harek")
      payload = {
        "people" => [ { "name" => "Harek", "subrole" => "contact", "gist" => "the relay man" } ],
        "facts"  => [ { "content" => "Harek runs messages past the toll bridge.", "concerns" => [] } ]
      }
      capture(payload, context: ctx)
      expect(Knowledge.last.content).to eq("Harek runs messages past the toll bridge.")
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

    # The payload carries one local fact; the llm's only complete() call is the
    # merge judge, which returns `verdict`. Embeds map any text to the same
    # vector as the standing row → cosine 1.0 → the judge always fires.
    def capture_revision(verdict, fact_content: "The founder was named Elara.", embed_vec: [ 1.0, 0.0 ])
      llm = StubLLM.new { |_p| verdict.to_json }
      llm.define_singleton_method(:embed) { |texts| Array(texts).map { embed_vec } }
      capture(facts("content" => fact_content, "scope" => "local"), llm: llm)
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
      llm = StubLLM.new { |_p| raise "judge must not fire" }
      llm.define_singleton_method(:embed) { |texts| Array(texts).map { [ 0.0, 1.0 ] } } # orthogonal to standing
      capture(facts("content" => "The harbor closes at dusk.", "scope" => "local"), llm: llm)

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

  describe "structural attribution" do
    it "overrides the model-written `by` with the actual speaker" do
      elsewhere = Location.create!(name: "Redmarsh")
      harek     = Npc.create!(name: "Harek", subrole: "ferryman", location: elsewhere)
      payload = {
        "people" => [ { "name" => "Harek", "subrole" => "ferryman", "by" => "Somebody Else" } ],
        "facts"  => [ { "content" => "Harek owes forty marks.", "concerns" => [ "Harek" ] } ]
      }
      expect { capture(payload, context: ctx, speaker: "Tomas") }.to change(Event, :count).by(1)
      expect(Event.last.participants).to include(harek)
    end

    it "drops a named self-mention (a speaker cannot volunteer themselves)" do
      tavern # force fixtures
      payload = { "facts" => [], "people" => [ { "name" => "Tomas", "subrole" => "barkeep", "gist" => "a sharp barkeep" } ] }
      expect { capture(payload, context: ctx, speaker: "Tomas") }.not_to change(Character, :count)
    end
  end

  describe "empty payload" do
    it "returns empty for a non-hash payload without touching the stores" do
      tavern
      expect(capture("not a hash at all")).to eq([])
      expect(Knowledge.count).to eq(0)
    end
  end
end
