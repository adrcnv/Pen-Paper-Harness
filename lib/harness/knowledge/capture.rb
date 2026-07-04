module Harness
  module Knowledge
    # Step 2 — the WRITE path, and a two-store ROUTER. After a conversation turn,
    # read what the NPCs actually SAID and persist it — but to the RIGHT store:
    #   - ATTRIBUTE-scoped fact (true of a CLASS or PLACE — "the salt tithe was
    #     repealed", "form 4-B goes to the strongroom") → the KNOWLEDGE store,
    #     faceted, read by every matching NPC.
    #   - PARTICIPATION-scoped fact (a private matter between SPECIFIC named
    #     parties — "Ingvar owes the counting house") → the EVENTS store, a
    #     single `personal`-scope event with those parties as participants. Only
    #     they recall it; `ids_for_holder` never projects a personal event to
    #     co-locators or the public, so it does NOT leak to the whole town.
    # The LLM tags each fact with `concerns` (the named parties); non-empty →
    # events, empty → knowledge. This is what keeps one person's claim from
    # becoming town doctrine.
    #
    # THE HARD JUDGMENT lives here and is what step 2 exists to de-risk:
    #   - is this a storable fact, or leverage-able trivia the model can just
    #     regenerate (how to skin a rabbit)? — the razor.
    #   - which STORE (the concerns fork above), and at what FACET GRANULARITY
    #     for the knowledge branch? too broad → one offhand remark becomes
    #     universal doctrine; too narrow → nothing fans out.
    # Validate by reading the rows this writes.
    #
    # Place granularity is mechanical for now: a "local" fact scopes to the
    # scene's ROOT settlement (town-wide), matching Query's ancestry up-chain so
    # every sublocation shares it; "world" scopes to null. Finer place tiers and
    # semantic dedup wait for later steps. Participation parties resolve to
    # EXISTING character rows only; a fact naming nobody who exists is skipped
    # (logged) and left for the realizer (step 4) — never demoted to knowledge.
    class Capture
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/knowledge_capture.txt")

      def self.run(**kwargs) = new(**kwargs).run

      def initialize(llm:, location:, lines:, game_time: 0, context: nil, logger: Rails.logger)
        @llm       = llm
        @location  = location
        @lines     = Array(lines)
        @game_time = game_time
        @context   = context   # Turn::Context — needed to REALIZE named people (nil → skip realization)
        @logger    = logger
      end

      # Returns the rows written — a mix of Knowledge (attribute-scoped) and
      # Event (participation-scoped) records (may be empty).
      def run
        return [] if @lines.empty?

        # Log what capture is JUDGING, at info — so a "0 written" turn isn't a
        # black box (was it fed banter, or did it wrongly reject a real fact?).
        @logger.info { "[Knowledge::Capture] judging #{@lines.size} line(s): #{@lines.map { |l| "#{l['speaker']}: #{l['says'].to_s[0, 100]}" }.inspect}" }

        raw    = ::Harness::CostTracker.in_subsystem(:knowledge_capture) do
          @llm.complete(system: preamble, user: user_message)
        end
        parsed = parse(raw)
        facts  = extract_facts(parsed)
        people = extract_people(parsed)
        places = extract_places(parsed)
        # Show the raw extraction (content + concerns) BEFORE routing/dedup, so
        # calibration is visible: what the razor kept, and where it routed it.
        facts.each { |f| @logger.info { "[Knowledge::Capture]   extracted: concerns=#{Array(f['concerns']).inspect} :: #{f['content'].to_s[0, 120]}" } }
        # People named in dialogue → the Realizer (the SINGLE entity pipe: this
        # replaces the old flaky `claims` side-field the voicing model kept
        # forgetting). Realized FIRST, so a fact about a just-minted person can
        # attach to their fresh row (find_character consults @minted_people) —
        # otherwise the participation branch would drop it as "no party". Needs a
        # Turn::Context; a no-op (empty map) without one (unit tests).
        realize_people(people)
        written = facts.filter_map { |f| route(f) }
        persist_embeddings(written)
        # Places named in dialogue → the PlaceRealizer (the buildings twin: mint a
        # proper-named sublocation of the current town). Independent of fact
        # routing; also a no-op without a context.
        realize_places(places)
        @logger.info { "[Knowledge::Capture] #{@lines.size} line(s) → #{facts.size} fact(s), #{written.size} written, #{people.size} person-ref(s), #{places.size} place-ref(s)" }
        written
      end

      # Embed the knowledge rows just written (one batched call) and cache the
      # vectors so recall's CosineRanker doesn't backfill them later. Knowledge
      # only — participation events rank by edge, not cosine. Non-fatal: a down
      # embedder just leaves the column nil for the ranker to fill lazily. Skips
      # entirely when the LLM client can't embed (test stubs, embed-less builds).
      def persist_embeddings(rows)
        return unless @llm.respond_to?(:embed)
        pending = rows.select { |r| r.is_a?(::Knowledge) && r.embedding.blank? }
        return if pending.empty?
        vecs = @llm.embed(pending.map(&:content))
        pending.zip(Array(vecs)).each do |row, vec|
          row.update_column(:embedding, JSON.generate(vec)) if vec.present?
        end
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] embedding persist failed (non-fatal): #{e.class}: #{e.message}" }
      end

      private

      # The fork: a fact naming specific parties is participation-scoped (→ an
      # event those parties own); everything else is attribute-scoped (→ faceted
      # knowledge). `concerns` is the LLM's entity-extraction — the one judgment
      # that keeps a private claim out of town-wide knowledge.
      def route(fact)
        parties = Array(fact["concerns"]).select { |n| n.is_a?(String) && !n.strip.empty? }
        parties.any? ? write_event(fact, parties) : write_knowledge(fact)
      end

      def user_message
        payload = {
          "location"  => @location&.name,
          "vocations" => ::Harness::Vocations.all,
          "lines"     => @lines.map { |l| { "speaker" => l["speaker"], "says" => l["says"] } }
        }
        "INPUT:\n#{JSON.pretty_generate(payload)}"
      end

      def parse(raw)
        ::Harness::LLM::JsonResponse.parse(raw)
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] parse failed: #{e.class}: #{e.message}" }
        nil
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
        return @minted_people if @context.nil? || people.empty?
        people.each do |p|
          speaker = find_character(p["by"].to_s)
          claim   = { "name" => p["name"], "subrole" => p["subrole"], "gist" => p["gist"], "at_location" => p["at_location"] }
          res = ::Harness::NarrativeShift::Realizer.run(claim: claim, speaker: speaker, context: @context, logger: @logger)
          if res && (c = ::Character.find_by(id: res["character_id"]))
            @minted_people << c unless @minted_people.include?(c)
          end
          @logger.info do
            status = if res.nil? then "declined"
            elsif res["minted"] then "MINTED ##{res['character_id']} #{res['name'].inspect}"
            elsif res["linked"] then "LINKED ##{res['character_id']} #{res['name'].inspect}"
            else res.inspect end
            "[Knowledge::Capture] realize person by=#{p['by'].inspect} name=#{p['name'].inspect} → #{status}"
          end
        end
        @minted_people
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] person realize failed (non-fatal): #{e.class}: #{e.message}" }
        @minted_people
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
            else res.inspect end
            "[Knowledge::Capture] realize place name=#{pl['name'].inspect} → #{status}"
          end
        end
      rescue StandardError => e
        @logger.warn { "[Knowledge::Capture] place realize failed (non-fatal): #{e.class}: #{e.message}" }
      end

      # ATTRIBUTE branch — a faceted Knowledge row: resolve facets mechanically,
      # dedup, write. Returns the row, or nil if it was a duplicate.
      def write_knowledge(fact)
        content     = fact["content"].strip
        subrole     = canonical_subrole(fact["subrole"])
        location_id = local_scope?(fact["scope"]) ? root_settlement_id : nil
        min_int     = fact["min_int"].is_a?(Integer) ? fact["min_int"] : nil

        return nil if duplicate?(content, subrole, location_id)

        row = ::Knowledge.create!(
          content:     content,
          subrole:     subrole,
          location_id: location_id,
          min_int:     min_int,
          current:     true,
          source_kind: "conversation",
          game_time:   @game_time
        )
        @logger.info { "[Knowledge::Capture] knowledge ##{row.id} subrole=#{subrole.inspect} loc=#{location_id.inspect} min_int=#{min_int.inspect} :: #{content}" }
        row
      end

      # PARTICIPATION branch — one `personal`-scope event owned by the named
      # parties. Resolve each name to an EXISTING character in the scene's
      # settlement; if none resolve, skip (the realizer will handle
      # nonexistent people in step 4). Unresolved names are kept as prose so
      # the fact stays legible. Returns the Event, or nil (skipped/duplicate).
      def write_event(fact, parties)
        content = fact["content"].strip
        chars, unresolved = resolve_parties(parties)

        if chars.empty?
          @logger.info { "[Knowledge::Capture] SKIP participation fact — no party resolved #{parties.inspect} (deferred to realizer) :: #{content}" }
          return nil
        end

        return nil if duplicate_event?(content, chars)

        details = { "narrative" => { "trigger" => "overheard", "details" => content } }
        details["concerns_unresolved"] = unresolved if unresolved.any?

        event = ::Harness::Event::ForwardAppender.append(
          game_time:    @game_time,
          scope:        "personal",
          location:     @location,
          details:      details,
          participants: chars.map { |c| { character: c, role: "subject" } }
        )
        @logger.info { "[Knowledge::Capture] event ##{event.id} parties=#{chars.map(&:name).inspect} unresolved=#{unresolved.inspect} :: #{content}" }
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
        ::Character.where(location_id: ids).find { |c| name_match?(c.name, name) }
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

      # Only an exact vocabulary member survives; anything else (null, "none", a
      # free-texted trade) becomes world-general on the trade axis.
      def canonical_subrole(v)
        ::Harness::Vocations.valid?(v) ? v : nil
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

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
