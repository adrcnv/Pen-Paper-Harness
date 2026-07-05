module Harness
  module Runners
    # The player speaks to the room. Each PRESENT character is voiced by its OWN
    # structured-emit call that sees ONLY its own events — so no character can
    # recite another's history (hard theory-of-mind). The weak local model can't
    # honor a "use only your own sub-array" rule when everyone's events sit in
    # one prompt, so we enforce the boundary mechanically: identities are public
    # (others_present — names + roles), knowledge is private (per-call events).
    #
    # Each character self-decides whether it is being addressed, so there is no
    # mechanical addressee resolver. We poll the named-likely characters first
    # (so a chime-in can't fill the answer before the addressee is asked) and
    # stop once two have spoken — a question usually draws one answer, sometimes
    # two at once, as in life.
    #
    # Per-character emit: speech (dialogue → staged propose_event), persuasion
    # (resolve_call → resolve), asserted ignorance (→ personal event), and a
    # durable beat (memorable → propose_event). NAMED PEOPLE are no longer a
    # per-emit field — the post-turn Knowledge::Capture pass is the single entity
    # pipe (facts + people → Realizer), so the voicing model doesn't have to
    # remember a `claims` side-field it kept dropping.
    class Conversation < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/conversation.txt")
      EVENT_SUMMARY_CAP = 10
      # Banter (non-substantive) speakers only react in-character — they don't
      # carry the turn's info load, so they get a thin slice of their own recent
      # events instead of the full dump. Keeps their (cheap, throwaway) voicing
      # prompt small; the substantive speaker still gets the full history.
      BANTER_EVENT_CAP = 3
      # The substantive speaker's own recent memories kept UNGATED for character
      # continuity — so gating its events by topic can never leave the info-carrier
      # thinner on self-knowledge than a banter NPC.
      RECALL_EVENT_FLOOR = 2
      EVENT_TEXT_CAP = 220
      THREAD_CAP  = 6
      THREAD_CHARS = 700
      MAX_SPEAKERS = 2
      PLACES_CAP  = 12
      RECALL_CAP  = 8

      def run(context:, scene:, input:, step:)
        present = Array(scene["present_characters"])
        extras  = Array(scene["present_extras"])
        return redispatch("no one present to converse with") if present.empty? && extras.empty?

        player = ::Player.first
        return redispatch("no player row") unless player

        resolver = resolver_for(context)
        active   = context.active_scene
        tcs      = []
        promo    = {}
        thread   = conversation_thread(context)
        roster   = present.map { |c| { "name" => c["name"], "subrole" => c["subrole"] } }
        nearby   = nearby_places(context)
        # ONE substantive speaker per turn carries the info load — it alone
        # recalls the KNOWLEDGE store (facet-relevant stored facts) and gates
        # them into its voicing. Everyone else banters on their own events only.
        substantive_id = pick_substantive(present, input)

        spoken       = 0
        parsed_any   = false
        spoken_lines = []
        poll_order(present, extras, input, step).each do |v|
          break if spoken >= MAX_SPEAKERS
          substantive = v[:kind] == :npc && v[:char]["id"] == substantive_id
          emit = voice_one(context, input, step, player, v, roster, thread, nearby, resolver, tcs, active, substantive)
          next unless emit
          parsed_any = true
          if apply_emit(resolver, context, scene, emit, v, player, promo, tcs)
            spoken += 1
            # First speaking turn consumed the seeded mood/agenda; from now on the
            # thread carries this NPC (npc_knowledge drops the frozen self-state).
            active&.mark_spoken!(v[:char]["id"]) if v[:kind] == :npc
          end
          collect_line(spoken_lines, v, emit)
        end

        return redispatch("conversation emit unparseable", tcs) unless parsed_any
        capture_knowledge(context, spoken_lines)
        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      private

      # Poll order: characters the player NAMED (by first name or role, in the
      # input or the planner intent) go FIRST — so an addressee is always asked
      # before the two-speaker cap can be filled by chime-ins (otherwise two
      # bystanders piping up could silence the person actually addressed). Extras
      # last: ambient figures only get drawn in if the named cast didn't already
      # answer the room. This is poll ORDER, not a speech ruling — each character
      # still self-decides whether it speaks.
      def poll_order(present, extras, input, step)
        hay = "#{input} #{step&.intent}".downcase
        npcs = present.map { |c| { kind: :npc, char: c } }
        named, rest = npcs.partition { |v| addressed_by_name?(v[:char], hay) }
        # Extras are ambient narration FLAVOR, not filler speakers. Poll one ONLY
        # when the player's input actually ENGAGES it ("talk to the recruit") —
        # engagement is what promotes an unnamed figure into a character. NEVER
        # poll an extra to top up the two-speaker cap: that let a whinnying horse
        # voice a present NPC and get minted into a phantom innkeeper. Unaddressed
        # ambience is narration's job; it never speaks here.
        engaged = Array(extras).each_with_index
          .select { |desc, _| addressed_extra?(desc, hay) }
          .map { |desc, i| { kind: :extra, index: i, desc: desc } }
        named + engaged + rest
      end

      def addressed_by_name?(char, hay)
        first = char["name"].to_s.split.first.to_s.downcase
        sub   = char["subrole"].to_s.downcase.tr("_", " ")
        (first.length >= 2 && hay.include?(first)) || (sub.length >= 2 && hay.include?(sub))
      end

      # An ambient extra is ENGAGED when the input names something distinctive
      # from its description — a content word of 4+ letters (mechanical + fuzzy,
      # the extras' analogue of addressed_by_name?). "talk to the recruit"
      # engages "a young recruit by the hearth"; "hello barkeep" engages no
      # extra, so a horse in the corner is never voiced.
      EXTRA_STOPWORDS = %w[from that with your look over back into their here some just].freeze
      def addressed_extra?(desc, hay)
        desc.to_s.downcase.scan(/[a-z]{4,}/)
            .reject { |w| EXTRA_STOPWORDS.include?(w) }
            .any? { |w| hay.include?(w) }
      end

      # THE SUBSTANTIVE SPEAKER (mechanical, no LLM): the present NPC with the
      # most facet-relevant stored knowledge for this topic carries the info
      # load this turn. Returns their id, or nil when NOBODY has any matching
      # knowledge (then no recall/gate fires — everyone banters, zero LLM cost).
      # A proxy for "best topic×facet match"; once cosine ranks (behind the
      # Query seam) the count already reflects topic, not just facet.
      def pick_substantive(present, topic)
        scored = Array(present).filter_map do |c|
          char = ::Npc.find_by(id: c["id"]) or next
          n = ::Harness::Knowledge::Query.for(character: char, topic: topic, limit: RECALL_CAP).size
          n.positive? ? [ c["id"], n ] : nil
        end
        return nil if scored.empty?
        winner = scored.max_by { |_, n| n }
        @logger.info { "[Runner conversation] substantive speaker id=#{winner[0]} (#{winner[1]} recall candidate(s)); scored=#{scored.inspect}" }
        winner[0]
      end

      # A gate candidate carrying a synthetic id (so knowledge-row ids and
      # event-row ids can't collide inside one gate call) + its source, so the
      # approved set splits back into facts vs memories.
      RecallItem = Struct.new(:id, :content, :src)

      # UNIFIED recall for the substantive speaker: knowledge facts (facet-gated,
      # cosine-ranked) AND this NPC's own participation memories (already fetched
      # as `own_events`) go through ONE relevance gate. Returns the gate-approved
      # set split by source — so the raw last-10 event dump is replaced by the
      # memories that actually bear on the question, alongside the relevant facts.
      # `own_events` are the recency-ordered event texts npc_knowledge already
      # pulled (no second query); knowledge is cosine-ranked to bound what the
      # gate sees. Empty candidate set → empty result (no gate call).
      def recall(context, char, topic, own_events)
        ranker = ::Harness::Knowledge::CosineRanker.new(embedder: llm(context), logger: @logger)
        facts  = ::Harness::Knowledge::Query.for(character: char, topic: topic, limit: RECALL_CAP, ranker: ranker)

        cands = []
        facts.each        { |k|   cands << RecallItem.new(cands.size + 1, k.content, :knowledge) }
        Array(own_events).each { |t| cands << RecallItem.new(cands.size + 1, t, :event) }
        return { "knowledge" => [], "events" => [] } if cands.empty?

        approved = ::Harness::Knowledge::Gate.run(llm: llm(context), topic: topic, facts: cands, logger: @logger)
        out = { "knowledge" => approved.select { |c| c.src == :knowledge }.map(&:content),
                "events"    => approved.select { |c| c.src == :event }.map(&:content) }
        @logger.info { "[Runner conversation] recall #{char.name}: #{facts.size} fact + #{Array(own_events).size} memory cand → #{out['knowledge'].size} fact / #{out['events'].size} memory gated-in" }
        out
      end

      # Voice ONE character. The call sees this character's own events (or, for
      # an extra, just its description), the public roster of who else is here,
      # and the shared thread — never anyone else's events.
      def voice_one(context, input, step, player, v, roster, thread, nearby, resolver, tcs, active, substantive = false)
        you =
          if v[:kind] == :extra
            { "ambient" => true, "index" => v[:index], "desc" => v[:desc] }
          else
            # Substantive speaker carries the info load → full event history;
            # banter NPCs get a thin slice (cheaper prefill for a throwaway line).
            npc_knowledge(resolver, v[:char], tcs, active, event_cap: substantive ? EVENT_SUMMARY_CAP : BANTER_EVENT_CAP)
          end
        # Substantive speaker only: recall facts AND the NPC's own memories
        # through one relevance gate. The gated-relevant memories (plus a small
        # recency floor for continuity) REPLACE the raw event dump; relevant
        # facts land in `knowledge`.
        if substantive && v[:kind] == :npc && (npc_row = ::Npc.find_by(id: v[:char]["id"]))
          r = recall(context, npc_row, input, you["events"])
          floor = Array(you["events"]).first(RECALL_EVENT_FLOOR)
          you = you.merge("events" => (floor + r["events"]).uniq)
          you = you.merge("knowledge" => r["knowledge"]) if r["knowledge"].any?
        end
        others = v[:kind] == :npc ? roster.reject { |r| r["name"] == v[:char]["name"] } : roster
        # Key ORDER matters for KV-cache reuse across the turn's per-NPC calls:
        # the invariant block (same player/input/intent/nearby/thread for every
        # speaker this turn) leads, so llama.cpp reuses that prefix; the per-NPC
        # varying blocks (others_present, you) come LAST. JSON is order-agnostic
        # to the model, so this is a pure prefill win, no behaviour change.
        user = JSON.pretty_generate(
          "player"          => { "id" => player.id, "name" => player.name },
          "player_input"    => input,
          "intent"          => step&.intent,
          "nearby_places"   => nearby,
          "exchange_so_far" => thread,
          "others_present"  => others,
          "you"             => you
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner conversation] voice failed: #{e.class}: #{e.message}" }
        nil
      end

      # Commit one character's emit. Returns true if the character SPOKE (so the
      # caller counts it toward the two-speaker cap). Raw dialogue is STAGED for
      # narration only; resolve / ignorance / memorable / claims persist on their
      # own consequential paths.
      def apply_emit(resolver, context, scene, emit, v, player, promo, tcs)
        dlg     = emit["dialogue"]
        prose   = dlg.is_a?(Hash) ? dlg["prose"].to_s.strip : ""
        engaged = emit["speak"] || prose != "" || emit["resolve_call"] || emit["ignorance"] || emit["memorable"]
        @logger.debug do
          who = v[:kind] == :npc ? v[:char]["name"] : "extra##{v[:index]}"
          "[Runner conversation] #{who} emit: speak=#{!!emit['speak']} dialogue=#{prose != ''} " \
          "resolve=#{!emit['resolve_call'].nil?} ignorance=#{!emit['ignorance'].nil?} memorable=#{emit['memorable'].is_a?(Hash)}"
        end
        return false unless engaged

        actor_id = actor_id_for(v, emit, resolver, context, scene, promo, tcs)
        return false unless actor_id

        spoke = false
        if prose != ""
          stage_line(actor_id, player, dlg, tcs)
          spoke = true
        end
        commit_resolve(resolver, emit["resolve_call"], player, actor_id, tcs)
        commit_ignorance(resolver, emit["ignorance"], player, actor_id, tcs)
        commit_memorable(resolver, emit["memorable"], player, actor_id, tcs)
        spoke
      end

      # The speaker's character_id: a real NPC carries its own id; an ambient
      # extra is materialized on first engagement (mechanical name, emit-supplied
      # subrole, description carried forward) via the shared promote path.
      def actor_id_for(v, emit, resolver, context, scene, promo, tcs)
        return v[:char]["id"] if v[:kind] == :npc
        promote_extra(resolver, context, scene, v[:index], emit["subrole"], into: tcs, cache: promo)
      end

      # Prefetch what THIS character could plausibly know (Ruby/SQL, no LLM) AND
      # who they are to voice — personality (stored at materialization), current
      # mood and scene agenda (seeded at scene entry). query_events already
      # scopes to this holder (own + witnessed + local), so the events list is
      # strictly this character's knowledge; no other character's memories enter.
      def npc_knowledge(resolver, char, tcs, active, event_cap: EVENT_SUMMARY_CAP)
        res, _ = execute_tool(resolver, "query_events", { "for_holder_id" => char["id"], "limit" => event_cap }, into: tcs)
        events = Array(res.is_a?(Hash) ? res["events"] : res)
          .map { |e| event_text(e) }
          .reject(&:empty?)
        props = ::Npc.find_by(id: char["id"])&.properties
        # Seeded mood/agenda only on the OPENING stance — once this NPC has spoken
        # this scene, the thread carries them and the frozen self-state is dropped
        # (see Active#spoken?). personality/lens/events persist.
        fresh = !active&.spoken?(char["id"])
        {
          "id"          => char["id"],
          "name"        => char["name"],
          "subrole"     => char["subrole"],
          "lens"        => char["lens"],
          "personality" => (props["personality"] if props.is_a?(::Hash)),
          "mood"        => (active&.state_for(char["id"]) if fresh),
          "agenda"      => (active&.agenda_for(char["id"]) if fresh),
          "events"      => events
        }.compact
      end

      # Pull the human-readable line out of a query_events row. `details` is a
      # JSON hash, NOT a flat string: genesis/catch-up events carry
      # {"summary" => "..."}, propose_event/conversation events carry
      # {"narrative" => {"trigger", "details"}}.
      def event_text(e)
        return e.to_s[0, EVENT_TEXT_CAP] unless e.is_a?(::Hash)
        d = e["details"]
        text =
          if d.is_a?(::Hash)
            narr = d["narrative"]
            if narr.is_a?(::Hash)
              [ narr["trigger"], narr["details"] ].compact.reject(&:empty?).join(" — ")
            else
              d["summary"] || d["details"] || d["trigger"] || ""
            end
          else
            d.to_s
          end
        text.to_s.strip[0, EVENT_TEXT_CAP].to_s
      end

      # The physical places around the speakers: the settlement they're in and
      # its other locations (the sawmill, the shrine, the smithy), plus any
      # sublocations of where they stand. Surfaced into every voicing call so an
      # NPC reaches for a REAL neighbouring place instead of inventing a second
      # one — the logging-hamlet-grows-a-second-sawmill bug. This is the
      # grounding-first lever: fill the vacuum that invention otherwise fills.
      # The semantic kind lives in the name ("the Smith's"), so name + a short
      # description snippet is enough for the model to pick the right one.
      def nearby_places(context)
        loc = context.player_location
        return [] unless loc
        rows = []
        rows << loc.parent if loc.parent
        if loc.parent_id
          rows.concat(::Location.where(parent_id: loc.parent_id).where.not(id: loc.id).limit(PLACES_CAP).to_a)
        end
        rows.concat(::Location.where(parent_id: loc.id).limit(PLACES_CAP).to_a)
        rows.uniq(&:id).first(PLACES_CAP).map do |l|
          entry = { "name" => l.name }
          d = l.description.to_s.strip
          entry["about"] = d[0, 80] unless d.empty?
          entry
        end
      end

      # The scene's thread up to now — the prior input→narration pairs, shared
      # across every character's call (what was said aloud is public). Runners
      # execute BEFORE this turn's narration is appended, so `narrations` is the
      # conversation up to (not including) the current line.
      def conversation_thread(context)
        active = context.active_scene
        return [] unless active
        Array(active.narrations).last(THREAD_CAP).map do |h|
          { "player" => h["input"].to_s, "scene" => h["narration"].to_s[0, THREAD_CHARS] }
        end
      end

      # Stage a line for NARRATION without PERSISTING it. Committing every "she
      # slams her mug" as a durable event is what fills a thin character's soul
      # with atmosphere and feeds it back as knowledge next turn. Intra-scene
      # memory comes from exchange_so_far; durable memory comes only from
      # memorable (+ resolve / ignorance / claims, consequential by nature).
      def stage_line(actor_id, player, dlg, tcs)
        args = {
          "scope"        => "local",
          "participants" => [
            { "character_id" => actor_id,  "role" => "actor" },
            { "character_id" => player.id, "role" => "participant" }
          ],
          "trigger"      => dlg["summary"].to_s[0, 60].presence || "exchange",
          "details"      => dlg["prose"],
          "time_minutes" => 5
        }
        tcs << tool_call("propose_event", args, { "staged" => true, "summary" => "[dialogue — rendered, not persisted]" })
      end

      # Persuasion: the PLAYER rolls charisma to extract something the character
      # would hesitate to share. actor is always the player; target is this
      # character.
      def commit_resolve(resolver, rc, player, target_id, tcs)
        return unless rc.is_a?(Hash) && rc["action"]
        execute_tool(resolver, "resolve", {
          "actor_id"     => player.id,
          "stat"         => rc["stat"] || "charisma",
          "action"       => rc["action"],
          "target_id"    => target_id,
          "difficulty"   => rc["difficulty"],
          "time_minutes" => rc["time_minutes"] || 5
        }, into: tcs)
      end

      # A durable "told the player they have not heard of X" record (personal
      # scope), so a later turn knows this character already denied the topic.
      def commit_ignorance(resolver, ig, player, actor_id, tcs)
        return unless ig.is_a?(Hash) && ig["topic"].to_s.strip != ""
        who = ::Npc.find_by(id: actor_id)&.name || "The NPC"
        execute_tool(resolver, "propose_event", {
          "scope"        => "personal",
          "participants" => [
            { "character_id" => actor_id,  "role" => "actor" },
            { "character_id" => player.id, "role" => "participant" }
          ],
          "trigger"      => "asserted ignorance",
          "details"      => "#{who} told the player they have not heard of #{ig['topic']}",
          "time_minutes" => 1
        }, into: tcs)
      end

      # The ONE durable event a character's turn can earn — ONLY when the emit
      # flags the exchange as consequential. The conservative default: commit
      # nothing unless it mattered.
      def commit_memorable(resolver, memorable, player, actor_id, tcs)
        return unless memorable.is_a?(Hash)
        gist = memorable["gist"].to_s.strip
        return if gist.empty?
        execute_tool(resolver, "propose_event", {
          "scope"        => "local",
          "participants" => [
            { "character_id" => actor_id,  "role" => "actor" },
            { "character_id" => player.id, "role" => "participant" }
          ],
          "trigger"      => gist[0, 60],
          "details"      => gist,
          "time_minutes" => 5
        }, into: tcs)
      end

      # Collect an NPC's actual spoken line for post-turn knowledge capture.
      # Only real NPCs with real dialogue prose (extras and no-op turns carry no
      # world-facts worth persisting yet).
      def collect_line(acc, v, emit)
        return unless v[:kind] == :npc
        prose = emit.dig("dialogue", "prose").to_s.strip
        return if prose.empty?
        acc << { "speaker" => v[:char]["name"], "says" => prose }
      end

      # Step 2 write path: extract standing world-facts from what was said and
      # persist them (Knowledge::Capture — the single entity pipe: facts + people
      # + places → Realizer). Fires on EVERY spoken turn — grounded turns
      # included: a speaker looking straight at a recalled fact is the prime
      # source of REVISIONS (capture's cosine-scan + merge judge ratifies the
      # elaboration into the standing row), and a grounded turn can still name
      # a new person/place the realizer must mint. (An earlier recall-miss arm
      # skipped grounded turns — valid for append-only capture, stale once
      # revision landed.) Non-fatal.
      def capture_knowledge(context, lines)
        return if lines.empty?
        ::Harness::Knowledge::Capture.run(
          llm:       llm(context),
          location:  context.player_location,
          lines:     lines,
          game_time: context.game_time,
          context:   context,   # enables person-realization (the single entity pipe)
          logger:    @logger
        )
      rescue StandardError => e
        @logger.warn { "[Runner conversation] knowledge capture failed: #{e.class}: #{e.message}" }
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
