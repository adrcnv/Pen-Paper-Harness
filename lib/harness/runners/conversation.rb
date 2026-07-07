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
    # durable beat (memorable → propose_event). World-facts / named people /
    # named places are harvested by a per-speaker REFLECTION pass: a second ask
    # on the speaker's still-hot voicing context ("you just said this — what
    # did you claim?"), so the judgment is made WITH the speaker's recall,
    # roster, and thread in view. (Two prior designs both failed: a same-call
    # `claims` side-field the model forgot while writing dialogue, and a
    # post-turn disembodied WORLD-MEMORY observer that saw bare lines and
    # re-minted the speaker herself as a stranger — the Stojan phantom.)
    class Conversation < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/conversation.txt")
      REFLECTION_PROMPT_PATH = Rails.root.join("lib/harness/prompts/knowledge_reflection.txt")
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
      # SANITY CEILING, not a budget: event lines feed both the voicing
      # you-block AND the recall-gate candidates, and a memory cut mid-sentence
      # is a corrupted premise in two judgments. Whole genesis narratives fit
      # under this; only pathological blobs get cut. (Char-truncation saves
      # ~nothing — prefill is fast and KV-cached; generation is the cost.)
      EVENT_TEXT_CAP = 600
      THREAD_CAP  = 6
      # Per-entry SANITY CEILING on the narration text carried into
      # exchange_so_far — catches only pathological blobs, never real turns
      # (700 silently ate the second speaker's paragraph; see
      # truncation-is-not-selection). Worst case 6 × 6000 chars ≈ 9K tokens,
      # comfortable in a 32K context window.
      THREAD_CHARS = 6000
      MAX_SPEAKERS = 2
      # Up to this many present NPCs carry recall (knowledge + gated memories)
      # into their voicing. Matches MAX_SPEAKERS so both possible speakers are
      # grounded — an ungrounded second speaker was both a coherence risk and a
      # blind spot for reflection capture. Cost: one extra gate call per turn.
      SUBSTANTIVE_CAP = 2
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
        # Up to SUBSTANTIVE_CAP speakers carry the info load — they recall the
        # KNOWLEDGE store (facet-relevant stored facts) and gate it into their
        # voicing. Everyone else banters on their own events only.
        substantive_ids = pick_substantives(present, input)

        spoken     = 0
        parsed_any = false
        speakers   = []
        poll_order(present, extras, input, step, active).each do |v|
          break if spoken >= MAX_SPEAKERS
          substantive = v[:kind] == :npc && substantive_ids.include?(v[:char]["id"])
          emit, voicing_user = voice_one(context, input, step, player, v, roster, thread, nearby, resolver, tcs, active, substantive)
          next unless emit
          parsed_any = true
          if apply_emit(resolver, context, scene, emit, v, player, promo, tcs)
            spoken += 1
            speakers << v[:char]["id"] if v[:kind] == :npc
            # First speaking turn consumed the seeded mood/agenda; from now on the
            # thread carries this NPC (npc_knowledge drops the frozen self-state).
            active&.mark_spoken!(v[:char]["id"]) if v[:kind] == :npc
            # Reflection immediately after the emit, while this speaker's
            # voicing prefix is still hot in the llama.cpp KV cache.
            reflect_knowledge(context, v, emit, voicing_user) if v[:kind] == :npc
          end
        end

        return redispatch("conversation emit unparseable", tcs) unless parsed_any
        active&.record_speakers!(speakers)
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
      def poll_order(present, extras, input, step, active = nil)
        hay = "#{input} #{step&.intent}".downcase
        npcs = present.map { |c| { kind: :npc, char: c } }
        named, rest = npcs.partition { |v| addressed_by_name?(v[:char], hay) }
        # Bystander cooldown: an unaddressed NPC who chimed in on the PREVIOUS
        # conversation turn sits this one out — not even polled, the call is
        # saved. No one can nag the player every single turn. Addressed NPCs
        # are exempt by the named partition; an NPC another character's last
        # line spoke to is exempt too (NPC↔NPC exchanges survive, at half
        # cadence). If the cooldown would leave nobody to poll (sole-NPC
        # scenes, "go on" inputs), it yields — a dead turn is worse than a
        # repeat chime-in.
        fresh, cooled = rest.partition { |v| !cooled_bystander?(v[:char], active) }
        rest = (named.empty? && fresh.empty?) ? cooled : fresh
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

      def cooled_bystander?(char, active)
        return false unless active&.spoke_last_turn?(char["id"])
        (active.last_lines || {}).none? do |id, line|
          id != char["id"] && addressed_by_name?(char, line.to_s.downcase)
        end
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

      # THE SUBSTANTIVE SPEAKERS (mechanical, no LLM): the present NPCs with the
      # most facet-relevant stored knowledge for this topic carry the info load
      # this turn, up to SUBSTANTIVE_CAP. Returns their ids ([] when NOBODY has
      # matching knowledge — then no recall/gate fires, everyone banters, zero
      # LLM cost). A proxy for "best topic×facet match"; once cosine ranks
      # (behind the Query seam) the count already reflects topic, not just facet.
      def pick_substantives(present, topic)
        scored = Array(present).filter_map do |c|
          char = ::Npc.find_by(id: c["id"]) or next
          n = ::Harness::Knowledge::Query.for(character: char, topic: topic, limit: RECALL_CAP).size
          n.positive? ? [ c["id"], n ] : nil
        end
        return [] if scored.empty?
        winners = scored.sort_by { |_, n| -n }.first(SUBSTANTIVE_CAP)
        @logger.info { "[Runner conversation] substantive speaker(s) #{winners.map { |id, n| "id=#{id}(#{n})" }.join(' ')}; scored=#{scored.inspect}" }
        winners.map(&:first)
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
          "location"        => location_payload(context),
          "nearby_places"   => nearby,
          "exchange_so_far" => thread,
          "others_present"  => others,
          "you"             => you
        )
        sent_user = "INPUT:\n#{user}"
        raw = ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          llm(context).complete(system: preamble, user: sent_user)
        end
        emit = parse_emit(raw)
        # The exact user string is returned alongside the emit so reflection
        # can extend it byte-identically (KV-cache prefix reuse).
        emit ? [ emit, sent_user ] : nil
      rescue StandardError => e
        @logger.warn { "[Runner conversation] voice failed: #{e.class}: #{e.message}" }
        nil
      end

      # WHERE the conversation is happening. Without this the voicing model
      # only saw nearby_places and would relocate the scene into the most
      # conversation-shaped entry (the Common Room leak: an open-air market
      # exchange narrated "through the din of the Common Room").
      def location_payload(context)
        loc = context.player_location
        return nil unless loc
        { "name" => loc.name, "part_of" => loc.parent&.name }.compact
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

        # REPEAT-GUARD (mechanical): the weak model, shown its own labeled
        # prior line in the thread, re-emits it near-verbatim turn after turn
        # (the prompt's "advance or break off" rule loses to structure). A
        # parrot emit is suppressed wholesale — the character breaks off, as
        # the rule demanded.
        active = context.active_scene
        if prose != "" && repeat_of_last_line?(active, actor_id, prose)
          who = ::Character.find_by(id: actor_id)&.name || actor_id
          @logger.info { "[Runner conversation] repeat suppressed — #{who} re-emitted their previous line; breaking off instead" }
          return false
        end

        spoke = false
        if prose != ""
          stage_line(actor_id, player, dlg, tcs)
          active&.record_line!(actor_id, prose)
          spoke = true
        end
        commit_resolve(resolver, emit["resolve_call"], player, actor_id, tcs)
        commit_ignorance(resolver, emit["ignorance"], player, actor_id, tcs)
        commit_memorable(resolver, emit["memorable"], player, actor_id, tcs)
        spoke
      end

      # A parrot: the new line reproduces ANY character's previous staged line
      # this scene — exact after normalization, or sharing a verbatim run of
      # ≥ PARROT_RUN chars (catches the observed shapes: own line regenerated
      # with one clause mutated, and a fresh action beat wrapping a chunk
      # copied from ANOTHER speaker's line — Sten reciting Ragnar's tail).
      # Scene-wide on purpose: copying a roommate's line is as broken as
      # copying your own. Formulaic short beats stay under the run floor.
      PARROT_RUN = 60
      def repeat_of_last_line?(active, _actor_id, prose)
        priors = (active&.last_lines || {}).values
        return false if priors.empty?
        a = normalize_line(prose)
        priors.any? do |last|
          b = normalize_line(last)
          a == b || shared_run?(a, b)
        end
      end

      def normalize_line(s)
        s.to_s.downcase.gsub(/\s+/, " ").strip
      end

      # Any PARROT_RUN-char window of `a` appearing verbatim in `b`. Brute
      # windows over two ≤~1-2K-char strings — trivial per turn.
      def shared_run?(a, b)
        return false if a.length < PARROT_RUN || b.length < PARROT_RUN
        (0..(a.length - PARROT_RUN)).any? { |i| b.include?(a[i, PARROT_RUN]) }
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
          "appearance"  => ((props["appearance"] || props["physical"]) if props.is_a?(::Hash)),
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
          # Sanity ceiling — 80 cut one-liner descriptions mid-word
          # ("smelling of wet ea"); a whole description is selection's job
          # (it's already a one-liner), not truncation's.
          entry["about"] = d[0, 240] unless d.empty?
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
      #
      # NOTE: a `[Name] ` speaker-label prefix was tried here (attribution for
      # the thread — the Vaela role-swap) and RETIRED same day: the weak model
      # treated its own cleanly-labeled prior paragraph as a template and
      # re-emitted it near-verbatim turn after turn. The repeat-guard survives
      # it; attribution now rides on the un-truncated thread alone.
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

      # REFLECTION — the knowledge write path. A second ask on the speaker's
      # still-hot voicing context: same system, same user prefix (KV-cache
      # reuse), plus a tail quoting what they just said and asking what they
      # claimed. The judgment is made WITH the speaker's recall/roster/thread
      # in view — a statement is only a NEW claim relative to what the speaker
      # could see, which the old disembodied observer never could. Extraction
      # lands in Knowledge::Capture.ingest (routing, realizers, dedup,
      # revision — unchanged). Speaker attribution is structural, not
      # model-reported. Non-fatal.
      def reflect_knowledge(context, v, emit, voicing_user)
        prose = emit.dig("dialogue", "prose").to_s.strip
        return if prose.empty? || voicing_user.nil?

        speaker = v[:char]["name"]
        raw = ::Harness::CostTracker.in_subsystem(:knowledge_capture) do
          llm(context).complete(system: preamble, user: "#{voicing_user}\n\n#{reflection_tail(prose)}")
        end
        payload = ::Harness::LLM::JsonResponse.parse(raw)
        unless payload.is_a?(::Hash)
          @logger.warn { "[Runner conversation] reflection unparseable for #{speaker} — nothing captured" }
          return
        end
        ::Harness::Knowledge::Capture.ingest(
          payload:   payload,
          speaker:   speaker,
          llm:       llm(context),
          location:  context.player_location,
          game_time: context.game_time,
          context:   context,   # enables person/place realization (the single entity pipe)
          logger:    @logger
        )
      rescue StandardError => e
        @logger.warn { "[Runner conversation] reflection capture failed for #{v[:char]['name']}: #{e.class}: #{e.message}" }
      end

      # <<...>> markers are runtime substitutions owned by THIS runner —
      # deliberately not {{...}}, which is Prompts::Preamble's vocabulary
      # namespace (its integration spec rejects unexpanded {{ in prompt files).
      def reflection_tail(prose)
        @reflection_template ||= File.read(REFLECTION_PROMPT_PATH)
        @reflection_template.sub("<<SAID>>") { prose }
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
