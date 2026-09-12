module Harness
  module Knowledge
    # The knowledge-write INGESTION pipe, and a two-store ROUTER. Extraction
    # happens upstream — each speaker judges their OWN line in a reflection
    # pass on their voicing context (Runners::Conversation#reflect_knowledge),
    # so the what-did-I-claim judgment is made with the speaker's recall,
    # roster, and thread in view. This class takes that parsed payload and
    # persists it to the RIGHT store:
    #   - TEMPORALLY UNBOUND fact (true of a CLASS or PLACE — "the salt tithe
    #     was repealed", "form 4-B goes to the strongroom") → the KNOWLEDGE
    #     store, faceted, read by every matching NPC.
    #   - DATED HAPPENING (a parseable `when` — "the mill burned two winters
    #     ago") or a private matter between SPECIFIC named parties ("Ingvar
    #     owes the counting house") → the EVENTS store, a single
    #     `personal`-scope event owned by the speaker + the named parties.
    #     Only they recall it; `ids_for_holder` never projects a personal
    #     event to co-locators or the public, so it does NOT leak town-wide.
    # `when` decides the temporal axis (dated → event, backdated game_time);
    # `concerns` decides privacy (named parties → event even undated). This is
    # what keeps one person's claim from becoming town doctrine.
    #
    # Place granularity is mechanical for now: a "local" fact scopes to the
    # scene's ROOT settlement (town-wide), matching Query's ancestry up-chain so
    # every sublocation shares it; "world" scopes to null. Participation parties
    # resolve to EXISTING character rows only; a fact naming nobody who exists
    # is skipped (logged) and left for the realizer — never demoted to
    # knowledge. Speaker attribution is STRUCTURAL: the `speaker` arg overrides
    # any `by` the model wrote, and a named self-mention is dropped (you cannot
    # volunteer yourself).
    class Capture
      MERGE_PROMPT_PATH = Rails.root.join("lib/harness/prompts/knowledge_merge.txt")

      # Cosine floor for treating an incoming fact as a REVISION of a standing
      # row rather than a new one. The merge judge is the precision gate; this
      # bounds how often it fires. Tuned on evidence: these decoder embeddings
      # live in a compressed band — two UNRELATED facts (player-spellweaver vs
      # Reeve-timber) scored 0.763, so the original 0.55 floor was below the
      # noise floor and would fire the judge on everything. Scans log their
      # scores; keep tuning as data accumulates.
      REVISION_THRESHOLD = 0.75

      def self.ingest(**kwargs) = new(**kwargs).ingest

      # player_spoke: false when the reflected line was UNPROMPTED (the
      # initiative pass) — the player addressed no one this turn, so no
      # bargain can bind them as debtor: a deal is spoken and accepted by
      # both sides, and one side was silent.
      # records: what the speaker was HANDED before speaking — {"events" =>
      # [[id, text]...], "facts" => [[id, text]...]}; the judge's
      # event_additions / fact_additions name these by 1-based position.
      def initialize(payload:, speaker:, llm:, location:, game_time: 0, context: nil, player_spoke: true, records: nil, logger: Rails.logger)
        @payload   = payload    # the speaker's parsed reflection output {facts, people, places}
        @records   = records || {}
        @speaker   = speaker.to_s
        @llm       = llm        # revision judge + embeddings only (no extraction call)
        @location  = location
        @game_time = game_time
        @context   = context   # Turn::Context — needed to REALIZE named people (nil → skip realization)
        @player_spoke = player_spoke
        @logger    = logger
      end

      # Returns the rows written — a mix of Knowledge (attribute-scoped) and
      # Event (participation-scoped) records (may be empty).
      def ingest
        return [] unless @payload.is_a?(::Hash)

        facts  = extract_facts(@payload)
        people = attribute_people(extract_people(@payload))
        places = extract_places(@payload)
        deals  = extract_deals(@payload)
        # Show the raw extraction (content + concerns) BEFORE routing/dedup, so
        # calibration is visible: what the razor kept, and where it routed it.
        facts.each { |f| @logger.info { "[Knowledge::Capture]   extracted: concerns=#{Array(f['concerns']).inspect} when=#{f['when'].inspect} :: #{f['content'].to_s[0, 120]}" } }
        # People named in dialogue → the Realizer (the SINGLE entity pipe).
        # Realized FIRST, so a fact about a just-minted person can attach to
        # their fresh row (find_character consults @minted_people) — otherwise
        # the participation branch would drop it as "no party". Needs a
        # Turn::Context; a no-op (empty map) without one (unit tests).
        realize_people(people)
        bake_bindings!(facts)
        # Deals BEFORE fact routing: the obligation owns its happening, so the
        # event branch can drop a same-pair re-description — the same bargain
        # emitted again under `facts`, usually in past tense ("Jay paid…"
        # while the ledger says owed — the split-brain).
        @deal_pairs = write_deals(deals)
        # Discharges AFTER deals: a bargain struck and acknowledged done in
        # the same breath (the paid-on-the-spot wage) settles at birth.
        settle_discharges(extract_discharges(@payload))
        written = facts.filter_map { |f| route(f) }
        written += write_additions(@payload)
        persist_embeddings(written)
        # Places named in dialogue → the PlaceRealizer (the buildings twin: mint a
        # proper-named sublocation of the current town). Independent of fact
        # routing; also a no-op without a context.
        realize_places(places)
        @logger.info { "[Knowledge::Capture] #{@speaker}: #{facts.size} fact(s), #{written.size} written, #{people.size} person-ref(s), #{places.size} place-ref(s), #{deals.size} deal(s)" }
        written
      end

      # Embed the knowledge rows just written (one batched call) and cache the
      # vectors so recall's CosineRanker doesn't backfill them later. Knowledge
      # only — participation events rank by edge, not cosine. Non-fatal: a down
      # embedder just leaves the column nil for the ranker to fill lazily. Skips
      # entirely when the LLM client can't embed (test stubs, embed-less builds).
      def persist_embeddings(rows)
        return unless @llm.respond_to?(:embed)
        pending = rows.select { |r| r.is_a?(::Knowledge) && stored_embedding(r).nil? }
        return if pending.empty?
        vecs = Embedding.embed(@llm, pending.map(&:content), kind: :passage)
        pending.zip(Array(vecs)).each do |row, vec|
          row.update_column(:embedding, Embedding.pack(vec, embed_model_stamp)) if vec.present?
        end
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] embedding persist failed (non-fatal): #{e.class}: #{e.message}" }
      end

      private

      # The fork, two independent axes:
      #   TEMPORAL — a parseable `when` means the claim is a dated HAPPENING →
      #     the events store, game_time backdated. Anything undated or vague
      #     ("many moons ago") is temporally unbound → knowledge, with the
      #     vagueness kept in the wording.
      #   PRIVACY — `concerns` (named parties) keeps a private matter out of
      #     town-wide knowledge: undated + parties → a personal event at
      #     current time (a standing private matter).
      # Events are participation-gated only (they happen to people, not
      # places); knowledge carries the place/facet levers.
      def route(fact)
        # Same-store law, backstopped: a fact that is a near-duplicate of a
        # record the speaker was handed is a retelling the judge failed to
        # file as an addition — it goes to its own store, never the other.
        content = fact["content"].to_s.strip
        if (twin = double_filed(content))
          @logger.info { "[Knowledge::Capture] SKIP fact — same claim filed as an addition this pass (#{twin.round(3)}) :: #{content}" }
          return nil
        end
        if (source = retelling_target(content))
          return source.is_a?(::Event) ? write_event_addition(source, content) : write_fact_addition(source, content)
        end
        parties = Array(fact["concerns"]).select { |n| n.is_a?(String) && !n.strip.empty? }
        happened_at = backdated_time(fact["when"])
        if happened_at
          write_event(fact, parties, at: happened_at)
        elsif parties.any?
          write_event(fact, parties)
        else
          write_knowledge(fact)
        end
      end

      # "3 days ago" / "two winters past" / "yesterday" / "last winter" →
      # absolute game_time (minutes), clamped at 0. Unparseable → nil (the
      # fact stays temporally unbound and routes to knowledge).
      UNIT_MINUTES = {
        "hour" => 60, "day" => 1_440, "night" => 1_440, "week" => 10_080, "moon" => 43_200, "month" => 43_200,
        "season" => 129_600, "winter" => 518_400, "summer" => 518_400, "year" => 518_400
      }.freeze
      WORD_NUMBERS = {
        "a" => 1, "an" => 1, "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5,
        "six" => 6, "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10, "twelve" => 12
      }.freeze
      WHEN_RE = /\A(?:about\s+|some\s+|nearly\s+|over\s+)?(\d+|#{WORD_NUMBERS.keys.join('|')})\s+(#{UNIT_MINUTES.keys.join('|')})s?\s+(?:ago|past|back)\z/i

      def backdated_time(raw)
        minutes = when_offset_minutes(raw)
        return nil if minutes.nil? || minutes.negative?
        [ @game_time.to_i - minutes, 0 ].max
      end

      # Same-day wordings are dated too: the happening is today, at the
      # current clock — an event, not a standing row with "this morning"
      # frozen into it.
      SAME_DAY_RE = /\A(?:today|earlier today|earlier|just now|this morning|this afternoon|this evening|at dawn today|this dawn)\z/
      def when_offset_minutes(raw)
        s = raw.to_s.strip.downcase
        return nil if s.empty?
        return 0 if s.match?(SAME_DAY_RE)
        return UNIT_MINUTES["day"] if s == "yesterday"
        if (m = s.match(/\Alast\s+(#{UNIT_MINUTES.keys.join('|')})\z/))
          return UNIT_MINUTES[m[1]]
        end
        return nil unless (m = s.match(WHEN_RE))
        n = WORD_NUMBERS[m[1]] || m[1].to_i
        n * UNIT_MINUTES[m[2].downcase]
      end

      # Structural attribution: `by` is the speaker whose reflection this is —
      # never trusted from the model. A NAMED self-mention is dropped (you
      # cannot volunteer yourself; the nameless variant is prevented upstream
      # by the first-person reflection framing).
      def attribute_people(people)
        player_name = ::Player.first&.name
        people.filter_map do |p|
          if name_match?(p["name"], @speaker)
            @logger.info { "[Knowledge::Capture] dropped self-mention #{p['name'].inspect} (speaker #{@speaker.inspect})" }
            next
          end
          # The player is in the room, never a referral: a people entry
          # naming them would mint a namesake NPC (the Osgyth twin — the
          # realizer's lookup sees NPC rows only).
          if player_name && name_match?(p["name"], player_name)
            @logger.info { "[Knowledge::Capture] dropped player-mention #{p['name'].inspect} (the player is not a referral)" }
            next
          end
          p.merge("by" => @speaker)
        end
      end

      def extract_facts(parsed)
        Array(parsed.is_a?(::Hash) ? parsed["facts"] : nil).select do |f|
          f.is_a?(::Hash) && f["content"].is_a?(String) && !f["content"].strip.empty?
        end
      end

      # People an NPC named who the player could seek out. A valid entry needs a
      # name OR a gist (the Realizer's own contract — a role-reference like "my
      # brother" carries a gist, no name, and the picker names them).
      def extract_people(parsed)
        Array(parsed.is_a?(::Hash) ? parsed["people"] : nil).select do |p|
          p.is_a?(::Hash) && (p["name"].to_s.strip != "" || p["gist"].to_s.strip != "")
        end
      end

      # DEALS — bargains struck ALOUD in this exchange, reported by the
      # speaker's own reflection (the obligations writer). The v1 razor is
      # mechanical: both parties must resolve to the SPEAKER or the PLAYER —
      # a deal between third parties is hearsay and doesn't bind. A same-pair
      # same-kind OPEN row already on the books is not re-struck (the
      # re-extraction drip: every later mention of the deal would otherwise
      # mint a twin). Returns the sorted id pairs it accepted (created or
      # already open) so the event branch can drop same-pair re-descriptions.
      def extract_deals(parsed)
        Array(parsed.is_a?(::Hash) ? parsed["deals"] : nil).select do |d|
          d.is_a?(::Hash) && ::Obligation::KINDS.include?(d["kind"].to_s) &&
            d["terms"].to_s.strip != "" && d["who_owes"].to_s.strip != "" && d["owed_to"].to_s.strip != ""
        end
      end

      def write_deals(deals)
        pairs = []
        deals.each do |d|
          debtor   = deal_party(d["who_owes"])
          creditor = deal_party(d["owed_to"])
          unless debtor && creditor && debtor.id != creditor.id
            @logger.info { "[Knowledge::Capture] deal dropped (parties must be speaker or player): #{d['who_owes'].inspect} owes #{d['owed_to'].inspect} — #{d['terms'].to_s[0, 80]}" }
            next
          end
          pair = [ debtor.id, creditor.id ].sort
          # The silent-player razor: an unprompted line cannot commit the
          # player to anything — they said nothing to accept. The pair is
          # still claimed so the same bargain can't slip in as a fact.
          if debtor.is_a?(::Player) && !@player_spoke
            @logger.info { "[Knowledge::Capture] deal dropped (player bound as debtor on a turn they did not speak): #{d['terms'].to_s[0, 80]}" }
            pairs << pair
            next
          end
          if ::Obligation.open_now.exists?(debtor_id: debtor.id, creditor_id: creditor.id, kind: d["kind"].to_s)
            @logger.info { "[Knowledge::Capture] deal skipped (open #{d['kind']} obligation #{debtor.name}→#{creditor.name} already on the books)" }
            pairs << pair
            next
          end
          # Machine-tense: a coin payment that already EXECUTED this turn is
          # history, not a debt — judged from the turn's tool trail, never
          # from the prose's tense (the model narrating the handover it also
          # performed must not double-book it as owed).
          if d["kind"] == "coins" && transfer_executed_this_turn?(debtor, creditor)
            @logger.info { "[Knowledge::Capture] deal skipped (transfer #{debtor.name}→#{creditor.name} already executed this turn — paid, not owed)" }
            pairs << pair
            next
          end
          amount = d["amount"].is_a?(::Integer) && d["amount"].positive? ? d["amount"] : nil
          row = ::Obligation.create!(
            debtor: debtor, creditor: creditor, kind: d["kind"].to_s, amount: amount,
            terms: d["terms"].to_s.strip[0, 300], due: d["due"].presence,
            due_time: ::Obligation.parse_due(d["due"], @game_time),
            status: "open", game_time: @game_time.to_i, location_id: deal_location_id(d["where"])
          )
          pairs << pair
          @logger.info { "[Knowledge::Capture] OBLIGATION ##{row.id} #{debtor.name} owes #{creditor.name} (#{row.kind}#{amount ? " #{amount}" : ''}): #{row.terms}" }
        rescue ::StandardError => e
          @logger.warn { "[Knowledge::Capture] deal write failed: #{e.class}: #{e.message}" }
        end
        pairs.uniq
      end

      # Meeting place: a spoken place naming an EXISTING location beats the
      # struck-location proxy (Whereabouts' meet tier keys on this). Link-only —
      # deals never mint places; unknown or absent → where the deal was struck.
      def deal_location_id(where)
        nm = where.to_s.strip
        unless nm.empty?
          loc = ::Location.where("LOWER(name) = ?", nm.downcase).first
          return loc.id if loc
        end
        @location&.id
      end

      # Both members of a deal pair struck this pass named in the sentence
      # (first names, word-bounded) → the fact is the deal re-described.
      def deal_owns_content?(content)
        Array(@deal_pairs).any? do |pair|
          names = ::Character.where(id: pair).pluck(:name)
          names.size == 2 && names.all? { |n| content.match?(/\b#{::Regexp.escape(n.split.first)}\b/i) }
        end
      end

      def transfer_executed_this_turn?(debtor, creditor)
        calls = @context.respond_to?(:turn_transcript) ? @context&.turn_transcript&.tool_calls : nil
        Array(calls).any? { |tc|
          tc["name"] == "transfer_coins" &&
            tc.dig("result", "from_id") == debtor.id && tc.dig("result", "to_id") == creditor.id
        }
      end

      def extract_discharges(parsed)
        Array(parsed.is_a?(::Hash) ? parsed["discharged"] : nil).select do |d|
          d.is_a?(::Hash) && ::Obligation::KINDS.include?(d["kind"].to_s) && d["who_owed"].to_s.strip != ""
        end
      end

      # The discharge writer — the mirror of write_deals: rows are born when
      # a deal is spoken, they die when release is spoken. The razor is
      # mechanical: only the CREDITOR releases, and the creditor is the
      # SPEAKER — the debtor claiming it's done settles nothing. Matches the
      # oldest open row of that kind between the pair; no row → the model
      # imagined a debt, drop silently.
      # A release is the CREDITOR's spoken word. Two legal shapes: the speaker
      # releasing a debt owed to them (who_owed = the debtor), or the player
      # releasing a debt the speaker owes (who_owed = the speaker). The player
      # has no reflection pass, so the debtor's own pass reports the player's
      # release — the same seat already reports the player's spoken acceptance
      # when a deal is struck. Never a third party, never self-to-self.
      def settle_discharges(discharges)
        return if discharges.empty?
        speaker = deal_party(@speaker)
        return unless speaker
        player = ::Player.first

        discharges.each do |d|
          named = deal_party(d["who_owed"])
          next unless named
          if named.id == speaker.id
            next unless player && player.id != speaker.id
            debtor, creditor = speaker, player
          else
            debtor, creditor = named, speaker
          end
          ob = ::Obligation.open_now.where(debtor_id: debtor.id, creditor_id: creditor.id, kind: d["kind"].to_s).order(:id).first
          unless ob
            @logger.info { "[Knowledge::Capture] discharge dropped (no open #{d['kind']} obligation #{debtor.name}→#{creditor.name})" }
            next
          end
          ob.update!(status: "settled")
          @logger.info { "[Knowledge::Capture] OBLIGATION ##{ob.id} SETTLED by #{creditor.name}'s word: #{ob.terms}" }
        rescue ::StandardError => e
          @logger.warn { "[Knowledge::Capture] discharge failed: #{e.class}: #{e.message}" }
        end
      end

      def deal_party(name)
        if name_match?(name, @speaker)
          @speaker_row = ::Character.find_by(name: @speaker) unless defined?(@speaker_row)
          return @speaker_row
        end
        player = ::Player.first
        return player if player && name_match?(name, player.name)
        nil
      end

      # Places an NPC named that could become real, findable rows. A valid entry
      # just needs a name; the PlaceRealizer rejects generics ("the mill").
      def extract_places(parsed)
        Array(parsed.is_a?(::Hash) ? parsed["places"] : nil).select do |p|
          p.is_a?(::Hash) && p["name"].to_s.strip != ""
        end
      end

      # Hand each named person to the Realizer (mint or link + ground event).
      # Speaker = the NPC who named them (resolved from `by`), or nil. Populates
      # @minted_people so a same-turn fact can attach to a fresh row. No-op (empty
      # map) without a context (the Realizer needs llm_grunt / player_location / game_time).
      def realize_people(people)
        @minted_people = []
        @realized_bindings = []
        return @minted_people if @context.nil? || people.empty?
        people.each do |p|
          speaker = find_character(p["by"].to_s)
          claim   = { "name" => p["name"], "subrole" => p["subrole"], "gist" => p["gist"], "at_location" => p["at_location"] }
          res = ::Harness::NarrativeShift::Realizer.run(claim: claim, speaker: speaker, context: @context, logger: @logger)
          if res && (c = ::Character.find_by(id: res["character_id"]))
            @minted_people << c unless @minted_people.include?(c)
            # A role-reference that realized to a differently-named row is a
            # binding the pass's own facts still don't know about.
            ref = p["name"].to_s.strip
            @realized_bindings << [ ref, res["name"] ] if !ref.empty? && !name_match?(res["name"], ref)
          end
          @logger.info do
            status = if res.nil? then "declined"
            elsif res["minted"] then "MINTED ##{res['character_id']} #{res['name'].inspect}"
            elsif res["linked"] then "LINKED ##{res['character_id']} #{res['name'].inspect}"
            else res.inspect
            end
            "[Knowledge::Capture] realize person by=#{p['by'].inspect} name=#{p['name'].inspect} → #{status}"
          end
        end
        @minted_people
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] person realize failed (non-fatal): #{e.class}: #{e.message}" }
        @minted_people
      end

      # Teach the pass's OWN facts a name assigned during realization, BEFORE
      # they're written: a role-worded fact ("the Guard-Captain is…") whose
      # person just minted as "Mereth Hexham" would otherwise enter the store
      # permanently orphaned from the row it's about (the two-Guard-Captains
      # seam — recall then serves roles no dialogue can resolve). APPEND, never
      # substitute: the speaker's wording stays verbatim and an appended clause
      # can't corrupt overlapping references. `concerns` is deliberately left
      # alone — adding a name there would REROUTE an attribute fact into a
      # participation event.
      def bake_bindings!(facts)
        Array(@realized_bindings).each do |ref, name|
          key = ::Harness::NarrativeShift::Realizer.reference_key(ref)
          next if key.empty?
          facts.each do |f|
            content = f["content"].to_s
            next unless content.downcase.include?(key)
            next if content.downcase.include?(name.to_s.downcase) # already named
            f["content"] = "#{content.strip} (#{ref} is #{name})"
          end
        end
      end

      # Hand each named place to the PlaceRealizer (mint a proper-named
      # sublocation of the current town, or link an existing one). No-op without
      # a context. Non-fatal.
      def realize_places(places)
        return if @context.nil? || places.empty?
        places.each do |pl|
          res = ::Harness::NarrativeShift::PlaceRealizer.run(place: pl, context: @context, logger: @logger)
          @logger.info do
            status = if res.nil? then "declined"
            elsif res["minted"] then "MINTED loc##{res['location_id']} #{res['name'].inspect}"
            elsif res["linked"] then "LINKED loc##{res['location_id']} #{res['name'].inspect}"
            else res.inspect
            end
            "[Knowledge::Capture] realize place name=#{pl['name'].inspect} → #{status}"
          end
        end
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] place realize failed (non-fatal): #{e.class}: #{e.message}" }
      end

      # ATTRIBUTE branch — a faceted Knowledge row: resolve facets mechanically,
      # dedup, then check whether this is a REVISION of a standing fact (the
      # modification plumbing — conversation elaborating a stored tale must
      # enrich the row recall reads, not strand a nameless sibling). Otherwise
      # write fresh. Returns the row written, or nil (duplicate / contradiction
      # / nothing-new revision).
      def write_knowledge(fact)
        content     = fact["content"].strip
        # Knowledge-side arm of one-writer-per-claim-class: with concerns
        # under-filled, a deal re-description routes here instead of the
        # event path and its pair guard. Knowledge rows carry no
        # participants, so the pair is matched by name in the sentence.
        if deal_owns_content?(content)
          @logger.info { "[Knowledge::Capture] SKIP knowledge fact — deal owns pair (both parties named) :: #{content}" }
          return nil
        end
        # Trade facet CUT for conversation-sourced facts (2026-07-07): the
        # speaker-POV reflection stamped the speaker's OWN trade on every
        # fact (3/3 in play), starving recall for everyone else — and a
        # claim voiced aloud to the player was never trade-gated anyway.
        # Re-facet from a neutral vantage if real trade-lore capture shows up.
        subrole     = nil
        # Conversation-born rows anchor at the settlement whatever the judge
        # wrote — a spoken claim never becomes world-general doctrine.
        location_id = root_settlement_id
        min_int     = fact["min_int"].is_a?(Integer) ? fact["min_int"] : nil

        return nil if duplicate?(content, subrole, location_id)

        old, vec = revision_target(content)
        if old
          verdict = judge_revision(old, content)
          case verdict["relation"]
          when "extends"
            merged = verdict["merged"].to_s.strip
            if merged.downcase == old.content.to_s.strip.downcase || merged.empty?
              @logger.info { "[Knowledge::Capture] revision of knowledge ##{old.id} added nothing — skipped as semantic duplicate :: #{content}" }
              return nil
            end
            return supersede(old, merged)
          when "contradicts"
            @logger.info { "[Knowledge::Capture] CONTRADICTS knowledge ##{old.id} — standing fact kept (stance, not fact-edit) :: #{content}" }
            return nil
          end
          # unrelated / unparseable verdict → cosine false positive; write fresh.
        end

        row = ::Knowledge.create!(
          content:     content,
          subrole:     subrole,
          location_id: location_id,
          min_int:     min_int,
          current:     true,
          source_kind: "conversation",
          speaker:     @speaker.presence,
          game_time:   @game_time,
          embedding:   (Embedding.pack(vec, embed_model_stamp) if vec.present?)
        )
        @logger.info { "[Knowledge::Capture] knowledge ##{row.id} subrole=#{subrole.inspect} loc=#{location_id.inspect} min_int=#{min_int.inspect} :: #{content}" }
        row
      end

      # REVISION SCAN — is this fact plausibly about the same subject as a
      # standing row? Candidates are current rows visible from the scene (the
      # place up-chain, same gate recall uses); cosine against the incoming
      # content; best score over the floor goes to the merge judge. Returns
      # [row_or_nil, incoming_vector_or_nil] — the vector is reused when the
      # fresh-write path runs, so nothing is embedded twice.
      def revision_target(content)
        return [ nil, nil ] unless @llm.respond_to?(:embed)
        candidates = revision_candidates
        return [ nil, nil ] if candidates.empty?

        vec = embed_once(content)
        return [ nil, nil ] if vec.nil? || vec.empty?

        scored = candidates.filter_map do |row|
          rv = stored_embedding(row)
          next if rv.nil?
          [ row, CosineRanker.similarity(vec, rv) ]
        end.sort_by { |_, s| -s }

        @logger.info do
          shown = scored.first(3).map { |row, s| "##{row.id}=#{s.round(3)}" }.join(" ")
          "[Knowledge::Capture] revision scan: #{scored.size}/#{candidates.size} scorable, top [#{shown}] (floor #{REVISION_THRESHOLD}) :: #{content[0, 80]}"
        end

        best, score = scored.first
        [ (best if score && score >= REVISION_THRESHOLD), vec ]
      end

      # Standing rows this scene could be elaborating: current, anchored
      # anywhere on the scene's place up-chain or world-general.
      def revision_candidates
        ancestry = Query.ancestor_location_ids(@location)
        scope = ::Knowledge.current
        if ancestry.any?
          scope.where("location_id IS NULL OR location_id IN (?)", ancestry).to_a
        else
          scope.where(location_id: nil).to_a
        end
      end

      def stored_embedding(row)
        Embedding.unpack(row.embedding, embed_model_stamp)
      end

      # One vector per sentence per pass — the retelling scan and the
      # revision scan share it.
      def embed_once(content)
        (@vecs ||= {})[content] ||= Array(Embedding.embed(@llm, [ content ], kind: :passage)).first
      end

      # PROVENANCE BACKSTOP — the fed rows are already embedded (recall ranked
      # them); the incoming sentence is embedded once. Best fed row over the
      # floor is the record this sentence retells. nil = a fresh claim.
      # Floors differ by embedder: the local pooled decoder embeddings sit in a
      # compressed band (unrelated pairs scored 0.76), the hosted embedding
      # model spreads (unrelated ≤ 0.35, same-story paraphrases 0.54–0.86 over
      # three Sonnet runs — a 0.539 miss at 0.55 set the floor). Keyed on the
      # model stamp; unknown models keep the conservative floor.
      RETELLING_THRESHOLD  = 0.9
      RETELLING_THRESHOLDS = { "nvidia/nemotron-3-embed-1b" => 0.45 }.freeze
      def retelling_threshold = RETELLING_THRESHOLDS.fetch(embed_model_stamp, RETELLING_THRESHOLD)

      def retelling_target(content)
        return nil unless @llm.respond_to?(:embed) && content.present?
        rows = fed_rows
        return nil if rows.empty?
        vec = embed_once(content)
        return nil if vec.nil? || vec.empty?
        scored = rows.filter_map { |row| (rv = stored_embedding(row)) && [ row, CosineRanker.similarity(vec, rv) ] }
                     .sort_by { |_, sc| -sc }
        best, score = scored.first
        return nil unless best
        @logger.info { "[Knowledge::Capture] retelling scan: top #{best.class.name}##{best.id}=#{score.round(3)} (floor #{retelling_threshold}) :: #{content[0, 80]}" }
        best if score >= retelling_threshold
      end

      # DOUBLE-FILING RAZOR — the judge's dominant lapse in play: the same
      # sentence entered as an addition AND as a fresh fact (the fact then
      # lands as knowledge with the date frozen in its wording — the fig
      # class through the other door). Comparing the fact to the OLD record
      # is the wrong comparison (a paraphrase of a week-old summary scored
      # 0.32–0.59); comparing it to the additions written in the SAME pass
      # is tight — two fresh sentences from the same mouth. Above the floor
      # the addition carries the claim and the fact is skipped. Returns the
      # score, or nil.
      DOUBLE_FILE_THRESHOLD = 0.7
      def double_filed(content)
        return nil unless @llm.respond_to?(:embed) && content.present?
        vecs = addition_vectors
        return nil if vecs.empty?
        vec = embed_once(content)
        return nil if vec.nil? || vec.empty?
        best = vecs.map { |av| CosineRanker.similarity(vec, av) }.max
        best if best && best >= DOUBLE_FILE_THRESHOLD
      end

      def addition_vectors
        @addition_vectors ||= begin
          texts = (Array(@payload["event_additions"]) + Array(@payload["fact_additions"]))
                    .select { |a| addition?(a) }.map { |a| a["content"].strip }.uniq
          texts.empty? ? [] : Array(Embedding.embed(@llm, texts, kind: :passage)).compact.reject(&:empty?)
        end
      end

      def fed_rows
        @fed_rows ||= ::Event.where(id: Array(@records["events"]).map(&:first).compact).to_a +
                      ::Knowledge.where(id: Array(@records["facts"]).map(&:first).compact).to_a
      end

      # ADDITIONS — the world judge's same-store writes: a detail added to a
      # record the speaker was handed. Ids are the payload's own 1-based
      # positions, mapped back to rows here; an id naming nothing is dropped
      # with a log. Each write is isolated — one bad addition must not cost
      # the pass its facts.
      def write_additions(parsed)
        rows = []
        seen = []   # one sentence lands once per pass — the same detail filed
                    # against two records of one chain is redundancy, not elaboration
        Array(parsed["event_additions"]).each do |a|
          next unless addition?(a)
          next if seen.include?(a["content"].strip.downcase)
          seen << a["content"].strip.downcase
          if (source = given_record("events", a["event_id"], ::Event))
            rows << write_event_addition(source, a["content"].strip)
          else
            @logger.info { "[Knowledge::Capture] event addition dropped (event_id #{a['event_id'].inspect} names no record given) :: #{a['content'].to_s[0, 80]}" }
          end
        rescue ::StandardError => e
          @logger.warn { "[Knowledge::Capture] event addition failed (non-fatal): #{e.class}: #{e.message}" }
        end
        Array(parsed["fact_additions"]).each do |a|
          next unless addition?(a)
          next if seen.include?(a["content"].strip.downcase)
          seen << a["content"].strip.downcase
          if (old = given_record("facts", a["fact_id"], ::Knowledge))
            rows << write_fact_addition(old, a["content"].strip)
          else
            @logger.info { "[Knowledge::Capture] fact addition dropped (fact_id #{a['fact_id'].inspect} names no record given) :: #{a['content'].to_s[0, 80]}" }
          end
        rescue ::StandardError => e
          @logger.warn { "[Knowledge::Capture] fact addition failed (non-fatal): #{e.class}: #{e.message}" }
        end
        # Telling is transmission: a handed event passed on, in detail or in
        # passing, is now known to everyone who was in the room.
        Array(parsed["retold"]).map(&:to_i).uniq.each do |k|
          if (source = given_record("events", k, ::Event))
            hear!([ source ])
          else
            @logger.info { "[Knowledge::Capture] retold id #{k.inspect} names no event given — ignored" }
          end
        rescue ::StandardError => e
          @logger.warn { "[Knowledge::Capture] retold write failed (non-fatal): #{e.class}: #{e.message}" }
        end
        rows.compact
      end

      # TRANSMISSION — the edge for "has heard of", distinct from having been
      # there: everyone in the room when a record is retold becomes a
      # participant of it with role "hearer". Participation is the event
      # store's own visibility currency, so the hearer recalls it from now on
      # (rendered as hearsay). The player hears too — the ledger of what the
      # player was told. Anyone already on the record, in any role, is left
      # alone; the teller never hears their own telling.
      def hear!(events)
        hearers = hearers_present
        return if hearers.empty?
        events.compact.uniq.each do |ev|
          on_record = ev.event_participants.pluck(:character_id).compact
          added = hearers.reject { |c| on_record.include?(c.id) }
          added.each { |c| ::EventParticipant.create!(event: ev, character: c, role: "hearer") }
          @logger.info { "[Knowledge::Capture] event ##{ev.id} heard by #{added.map(&:name).inspect}" } if added.any?
        end
      end

      def hearers_present
        @hearers_present ||= begin
          room = Array(@context&.active_scene&.present_characters).to_a
          ([ ::Player.first ] + room).compact.uniq(&:id).reject { |c| name_match?(c.name, @speaker) }
        end
      end

      def addition?(a) = a.is_a?(::Hash) && a["content"].is_a?(::String) && !a["content"].strip.empty?

      def given_record(kind, position, klass)
        i = position.to_i
        return nil unless i >= 1
        id = Array(@records[kind])[i - 1]&.first
        id && klass.find_by(id: id)
      end

      # event → event: a SUPPLEMENT event referencing its source, backdated to
      # it, scope and place inherited, the source's cast plus the teller. Events
      # are immutable; the chain is the elaboration. A verbatim retelling
      # supplements nothing.
      def write_event_addition(source, content)
        if content.downcase == source.recall_text.to_s.strip.downcase
          @logger.info { "[Knowledge::Capture] SKIP event addition — retells event ##{source.id} verbatim" }
          return nil
        end
        teller = find_character(@speaker)
        # The source's cast carries over with its roles kept — a hearer of the
        # source is a hearer of the supplement, never promoted to a subject
        # (that read as presence at recall). The teller is added as such.
        cast = source.event_participants.to_a.map { |p| [ p.character, (p.role == "hearer" ? "hearer" : "subject") ] }
        cast.reject! { |c, _| c.nil? }
        cast << [ teller, "teller" ] if teller && cast.none? { |c, _| c.id == teller.id }
        event = ::Harness::Event::ForwardAppender.append(
          game_time:    source.game_time,
          scope:        source.scope,
          location:     source.location,
          details:      { "narrative" => { "details" => content } },
          participants: cast.map { |c, role| { character: c, role: role } },
          references_event_id: source.id
        )
        @logger.info { "[Knowledge::Capture] event ##{event.id} SUPPLEMENTS ##{source.id} (t=#{source.game_time}, #{source.scope}) :: #{content}" }
        hear!([ source, event ])
        event
      end

      # knowledge → knowledge: the revision path with the target pinned (no
      # cosine scan — the judge named the row). Extends → supersede with the
      # merged wording; contradicts → the standing fact keeps; no relation →
      # the sentence stands on its own in the source's scope, never wider.
      def write_fact_addition(old, content)
        verdict = judge_revision(old, content)
        case verdict["relation"]
        when "extends"
          merged = verdict["merged"].to_s.strip
          if merged.empty? || merged.downcase == old.content.to_s.strip.downcase
            @logger.info { "[Knowledge::Capture] addition to knowledge ##{old.id} added nothing — skipped :: #{content}" }
            return nil
          end
          supersede(old, merged)
        when "contradicts"
          @logger.info { "[Knowledge::Capture] addition CONTRADICTS knowledge ##{old.id} — standing fact kept :: #{content}" }
          nil
        else
          write_knowledge("content" => content, "scope" => (old.location_id ? "local" : "world"), "concerns" => [])
        end
      end

      def embed_model_stamp
        @embed_model_stamp ||= Embedding.model_of(@llm)
      end

      # One grunt call: extends / contradicts / unrelated (+ merged text).
      # Any failure degrades to "unrelated" — the fact writes fresh rather
      # than being lost.
      def judge_revision(old, content)
        payload = { "standing_fact" => old.content, "new_statement" => content }
        raw = ::Harness::CostTracker.in_subsystem(:knowledge_capture) do
          @llm.complete(system: merge_preamble, user: "INPUT:\n#{JSON.pretty_generate(payload)}")
        end
        parsed = ::Harness::LLM::JsonResponse.parse(raw)
        parsed.is_a?(::Hash) ? parsed : {}
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] revision judge failed (writing fresh): #{e.class}: #{e.message}" }
        {}
      end

      # Replace a standing row with the merged revision. Facets inherit
      # VERBATIM — elaboration must never broaden scope. The old row drops out
      # of recall via `current: false`; supersedes_id is the audit link. The
      # new row's embedding is left nil for persist_embeddings to fill (the
      # merged text differs from what the scan embedded).
      def supersede(old, merged)
        row = ::Knowledge.create!(
          content:       merged,
          subrole:       old.subrole,
          location_id:   old.location_id,
          min_int:       old.min_int,
          social_class:  old.social_class,
          faction:       old.faction,
          current:       true,
          source_kind:   "conversation",
          # The REVISER's identity, not the original speaker's — the merged
          # wording is theirs. The old row keeps its own speaker; the
          # supersedes_id chain preserves the full provenance trail.
          speaker:       @speaker.presence,
          game_time:     @game_time,
          supersedes_id: old.id
        )
        old.update!(current: false)
        @logger.info { "[Knowledge::Capture] SUPERSEDE knowledge ##{old.id} → ##{row.id} :: #{merged}" }
        row
      end

      def merge_preamble
        @merge_preamble ||= File.read(MERGE_PROMPT_PATH)
      end

      # EVENT branch — one `personal`-scope event, participation-gated only.
      # Participants: the SPEAKER (the teller owns the memory of what they told
      # — also what lets the reflection razor see prior tellings) + each
      # `concerns` name resolved to an EXISTING character in the scene's
      # settlement. Unresolved names are kept as prose so the fact stays
      # legible. A dated fact (`at`) is the happening itself, backdated, no
      # trigger; an undated one is a standing private matter recorded at
      # current time. Returns the Event, or nil (skipped/duplicate).
      def write_event(fact, parties, at: nil)
        content = fact["content"].strip
        chars, unresolved = resolve_parties(parties)
        teller = find_character(@speaker)
        participants = ([ teller ] + chars).compact.uniq

        if participants.empty?
          @logger.info { "[Knowledge::Capture] SKIP event fact — teller #{@speaker.inspect} unknown, no party resolved #{parties.inspect} :: #{content}" }
          return nil
        end

        # A deal this pass claimed this pair: the obligation row owns the
        # happening, and an undated fact between the same two people is that
        # bargain re-described — usually in past tense ("paid" while the
        # ledger says owed). Dated facts pass: an explicit `when` places them
        # before this exchange.
        if at.nil? && Array(@deal_pairs).include?(participants.map(&:id).sort)
          @logger.info { "[Knowledge::Capture] SKIP event fact — deal owns pair #{participants.map(&:name).inspect} :: #{content}" }
          return nil
        end

        return nil if duplicate_event?(content, participants)

        narrative = at ? { "details" => content } : { "trigger" => "overheard", "details" => content }
        details = { "narrative" => narrative }
        details["concerns_unresolved"] = unresolved if unresolved.any?

        event = ::Harness::Event::ForwardAppender.append(
          game_time:    at || @game_time,
          scope:        "personal",
          location:     @location,
          details:      details,
          participants: participants.map { |c|
            { character: c, role: (c == teller && !chars.include?(c) ? "teller" : "subject") }
          }
        )
        @logger.info { "[Knowledge::Capture] event ##{event.id}#{at ? " backdated t=#{at}" : ""} parties=#{participants.map(&:name).inspect} unresolved=#{unresolved.inspect} :: #{content}" }
        event
      end

      # Split party names into resolved existing characters + names we couldn't
      # place. Matching is name-exact / first-token, scoped to the scene's
      # settlement subtree (same rule ProposeCharacter uses for collisions).
      def resolve_parties(names)
        chars = []
        unresolved = []
        names.each do |n|
          if (c = find_character(n))
            chars << c unless chars.include?(c)
          else
            unresolved << n
          end
        end
        [ chars, unresolved ]
      end

      # Resolve a party name to a Character. A person minted/linked THIS turn wins
      # first (a same-turn fact about them attaches even if they were homed
      # outside the current settlement); otherwise search the settlement subtree.
      def find_character(name)
        return nil if name.to_s.strip.empty?
        if (m = Array(@minted_people).find { |c| name_match?(c.name, name) })
          return m
        end
        ids = settlement_character_scope
        return nil if ids.nil?
        # Anchor OR cache: a resident belongs to the settlement wherever
        # their presence cache happens to sit (presence is schedule-derived;
        # the anchor is the durable membership fact).
        ::Character.where("location_id IN (:ids) OR home_location_id IN (:ids)", ids: ids)
                   .find { |c| name_match?(c.name, name) }
      end

      # Character rows anywhere in the scene's root-settlement subtree.
      def settlement_character_scope
        return @settlement_scope if defined?(@settlement_scope)
        root = @location
        return (@settlement_scope = nil) unless root
        root = root.parent while root.parent
        @settlement_scope = [ root.id ] + descendant_location_ids(root)
      end

      def descendant_location_ids(loc)
        children = ::Location.where(parent_id: loc.id).to_a
        children.map(&:id) + children.flat_map { |c| descendant_location_ids(c) }
      end

      def name_match?(a, b)
        a_norm = a.to_s.strip.downcase
        b_norm = b.to_s.strip.downcase
        return false if a_norm.empty? || b_norm.empty?
        return true  if a_norm == b_norm
        return true  if a_norm == b_norm.split(/\s+/).first
        return true  if b_norm == a_norm.split(/\s+/).first
        false
      end

      # Cheap event dedup: an identical fact already recorded for any of these
      # parties. Compares the narrative detail text, case-insensitively.
      def duplicate_event?(content, chars)
        norm = content.downcase
        event_ids = ::EventParticipant.where(character_id: chars.map(&:id)).pluck(:event_id).uniq
        ::Event.where(id: event_ids).any? do |e|
          e.details.is_a?(::Hash) &&
            e.details.dig("narrative", "details").to_s.strip.downcase == norm
        end
      end

      def local_scope?(scope) = scope.to_s.downcase == "local"

      # The town: walk the scene location up to its root. A local fact is known
      # town-wide, so it anchors at the top tier (Query's up-chain does the rest).
      def root_settlement_id
        loc = @location
        return nil unless loc
        loc = loc.parent while loc.parent
        loc.id
      end

      # Cheap dedup for now: same facets + case-insensitive identical content.
      # Semantic dedup (cosine) arrives with embeddings.
      def duplicate?(content, subrole, location_id)
        norm = content.downcase
        ::Knowledge.where(subrole: subrole, location_id: location_id)
                   .any? { |k| k.content.to_s.strip.downcase == norm }
      end
    end
  end
end
