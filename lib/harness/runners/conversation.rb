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
      REEVALUATION_PROMPT_PATH = Rails.root.join("lib/harness/prompts/mood_reevaluation.txt")
      EVENT_SUMMARY_CAP = 10
      # A speaker's own newest memories kept UNGATED for character continuity —
      # gating events by topic must never strip a character of immediate
      # self-knowledge.
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
        wares    = wares_here(context)
        # Planner-bound contest: the roll (if any) lands BEFORE anyone is
        # voiced — the target's payload gets the settled verdict, never the
        # judgment call.
        contest = run_contest(context, step, player, present, resolver, tcs, active)

        spoken     = 0
        parsed_any = false
        poll_order(present, extras, input, step).each do |v|
          break if spoken >= MAX_SPEAKERS
          emit, voicing_user = voice_one(context, input, step, player, v, roster, thread, nearby, wares, resolver, tcs, active, contest)
          next unless emit
          parsed_any = true
          if apply_emit(resolver, context, scene, emit, v, player, promo, tcs)
            spoken += 1
            # First speaking turn consumed the seeded mood/agenda; from now on the
            # thread carries this NPC (npc_knowledge drops the frozen self-state).
            active&.mark_spoken!(v[:char]["id"]) if v[:kind] == :npc
            # Reflection immediately after the emit, while this speaker's
            # voicing prefix is still hot in the llama.cpp KV cache. An
            # engaged extra reflects too, under the identity apply_emit just
            # minted — otherwise the debut line (usually the very claim the
            # player engaged them for) is an intake hole.
            if v[:kind] == :npc
              reflect_knowledge(context, v, emit, voicing_user)
              reevaluate_state(context, v, emit, voicing_user, active)
            elsif (minted = ::Character.find_by(id: promo[v[:index]]))
              reflect_knowledge(context, { char: { "name" => minted.name } }, emit, voicing_user)
            end
          end
        end

        return redispatch("conversation emit unparseable", tcs) unless parsed_any
        # Everyone declined (or was suppressed): mark the turn as an explicit
        # NON-response so narration renders the silence instead of filling the
        # vacuum with invented dialogue (the model's strongest prior on a
        # charged line is to write the reply itself).
        tcs << tool_call("conversation_silence", {}, { "nobody_spoke" => true }) if spoken.zero?
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

      # PLANNER-BOUND CONTEST (the dice binding): the planner read the input
      # and declared a contest on this step (args.check: target + optional
      # ability id). The roll happens here, mechanically, before any voicing.
      # One roll per (target, kind) per scene — the ledger returns the
      # standing verdict on repeat attempts (you don't get to re-ask the same
      # question harder; also kills the reroll/XP farm). An ability cast is a
      # DIFFERENT kind from bare persuasion, so a failed talk can still be
      # escalated with a charm. Fail-open: unresolvable target, unknown
      # ability with no fallback, or a resolve error → nil, plain conversation.
      def run_contest(context, step, player, present, resolver, tcs, active)
        spec = step&.args&.dig("check")
        return nil unless spec.is_a?(::Hash)

        target = find_present(present, spec["target"])
        unless target
          @logger.info { "[Runner conversation] contest target #{spec['target'].inspect} not present — skipped" }
          return nil
        end

        ability = player_ability(player, spec["ability"])
        kind    = ability ? ability["id"].to_s : "social"
        key     = "#{target['id']}:#{kind}"

        if (prior = active&.contest_for(key))
          @logger.info { "[Runner conversation] contest #{key} already settled this scene (#{prior['result']}) — reusing verdict" }
          return { target_id: target["id"], payload: prior }
        end

        args = { "actor_id" => player.id, "target_id" => target["id"],
                 "action" => (step&.intent.to_s.strip.empty? ? "press #{target['name']}" : step.intent) }
        if ability
          # resolve's lookup matches on display name, not id
          args["ability_name"] = ability["name"]
        else
          args["stat"]        = "charisma"
          args["target_stat"] = "wisdom"
        end

        res, ok = execute_tool(resolver, "resolve", args, into: tcs)
        # Tag the record: this resolve is a conversation contest whose verdict
        # the voicing renders in-fiction. The narration step reads the tag to
        # keep such turns in the dialogue-only skip — a narrator handed a
        # social verdict re-dramatizes it (invented quotes, contradicted
        # beats) ahead of the NPC's actual line.
        tcs.last["contest"] = true if tcs.last && tcs.last["name"] == "resolve"
        unless ok && res.is_a?(::Hash) && res["outcome"]
          @logger.warn { "[Runner conversation] contest roll failed (#{res.inspect[0, 140]}) — voicing plainly" }
          return nil
        end

        payload = { "kind" => (ability ? ability["name"] : "persuasion"), "result" => res["outcome"] }
        if ability && %w[success critical_success].include?(res["outcome"])
          payload["effect"] = ability["description"]
        end
        active&.record_contest!(key, payload)
        @logger.info { "[Runner conversation] contest #{key} → #{res['outcome']}#{res['xp_gained'] ? " (+#{res['xp_gained']}xp)" : ""}" }
        { target_id: target["id"], payload: payload }
      end

      # find_present / player_ability live in Runners::Base (shared with the
      # cast runner).

      # A gate candidate carrying a synthetic id (so knowledge-row ids and
      # event-row ids can't collide inside one gate call) + its source, so the
      # approved set splits back into facts vs memories.
      RecallItem = Struct.new(:id, :content, :src)

      # Semantic event recall (audit F4): how many newest knowable events join
      # the combined ranking pool. Bounds the lazy embedding backfill; vectors
      # persist on the row, so a mature town pays it once.
      EVENT_POOL = 40

      # UNIFIED recall for a speaker: knowledge facts
      # (facet-gated) AND this NPC's knowable memories in ONE pool, ONE cosine
      # rank against the topic, top RECALL_CAP through ONE relevance gate — an
      # on-topic memory outranks an off-topic fact and vice versa. Event lines
      # carry a relative-time prefix computed fresh from game_time (content is
      # stored timeless; the clock re-attaches "when" at read). Returns the
      # gate-approved set split by source. Empty pool → empty result (no gate
      # call).
      def recall(context, char, topic)
        ranker = ::Harness::Knowledge::CosineRanker.new(embedder: llm(context), logger: @logger)
        pool = ::Harness::Knowledge::Query.candidates_for(char) + event_pool(char)
        return { "knowledge" => [], "events" => [] } if pool.empty?

        ranked = ranker.call(pool, topic: topic).first(RECALL_CAP)
        cands = ranked.map.with_index(1) do |row, i|
          if row.is_a?(::Knowledge)
            RecallItem.new(i, row.content, :knowledge)
          else
            RecallItem.new(i, dated_memory_text(row, context.game_time), :event)
          end
        end

        approved = ::Harness::Knowledge::Gate.run(llm: llm(context), topic: topic, facts: cands, logger: @logger)
        out = { "knowledge" => approved.select { |c| c.src == :knowledge }.map(&:content),
                "events"    => approved.select { |c| c.src == :event }.map(&:content) }
        @logger.info { "[Runner conversation] recall #{char.name}: #{cands.count { |c| c.src == :knowledge }} fact + #{cands.count { |c| c.src == :event }} memory ranked-in → #{out['knowledge'].size} fact / #{out['events'].size} memory gated-in" }
        out
      end

      # The holder's knowable events (same edges as the you-block dump:
      # participation ∪ regional+ ∪ local-at-location), EVENT_POOL newest.
      # Fail-open to empty — the you-block's recency floor still carries
      # continuity.
      def event_pool(char)
        ids = ::Harness::Tools::QueryEvents.knowable_ids(char)
        return [] if ids.empty?
        # Text-less rows (resolve's mechanical logs) are blank candidates —
        # unembeddable clutter for the ranker and the gate; drop them here.
        ::Event.queryable.where(id: ids).order(game_time: :desc, id: :desc).limit(EVENT_POOL)
               .to_a.reject { |e| e.embed_text.strip.empty? }
      rescue StandardError => e
        @logger.warn { "[Runner conversation] event recall failed (floor only): #{e.class}: #{e.message}" }
        []
      end

      # "(2 moons past) the mill burned…" — the read-side half of the timeless
      # content contract: dates live in game_time, never in the wording, so
      # relative time is computed fresh here and can't go stale. Same-day
      # events get no prefix.
      def dated_memory_text(event, now)
        phrase = ago_phrase(now.to_i - event.game_time.to_i)
        phrase ? "(#{phrase}) #{event.recall_text}" : event.recall_text
      end

      def ago_phrase(delta_minutes)
        days = delta_minutes / ::Harness::Clock::MINUTES_PER_DAY
        return nil if days < 1
        return "yesterday" if days == 1
        return "#{days} days past" if days < 30
        n = days < 360 ? days / 30 : days / 360
        unit = days < 360 ? "moon" : "winter"
        "#{n} #{unit}#{'s' if n > 1} past"
      end

      # Voice ONE character. The call sees this character's own events (or, for
      # an extra, just its description), the public roster of who else is here,
      # and the shared thread — never anyone else's events.
      public

      # UNPROMPTED VOICING — the initiative consumer's door into the FULL
      # conversation machinery. The old thin beat surface (a one-line emit
      # with no personality, no events, no thread ownership) produced exactly
      # the ungrounded one-liners it was fed; this replaces it: the chosen NPC
      # speaks through voice_one with everything a speaking turn gets —
      # recall, mood/agenda, repeat guard, memorable, then reflection and
      # taking-stock. The frame overrides the are-you-addressed deliberation:
      # the selector already ruled that they act; the voicing decides only HOW.
      # Returns the staged prose, or nil (declined emit, parrot suppressed).
      UNPROMPTED_FRAME = <<~FRAME
        --- UNPROMPTED ---
        No one has addressed you this turn. You have RESOLVED to act on your own: <<CAUSE>>
        The are-you-speaking deliberation is settled — output the same JSON with "speak": true. Your dialogue.prose is you seizing the moment: say or do the thing, in your manner, grounded in what you actually know. player_input above is what the player just did, not words aimed at you.
      FRAME

      def voice_unprompted(context:, npc:, cause:, input:, transcript: nil)
        player = ::Player.first
        return nil unless player
        active   = context.active_scene
        resolver = resolver_for(context)
        scene    = ::Harness::Tools::QueryScene.build(context)
        present  = Array(scene["present_characters"])
        char     = present.find { |c| c["id"] == npc.id }
        return nil unless char

        roster = present.map { |c| { "name" => c["name"], "subrole" => c["subrole"] } }
        tcs    = []
        v      = { kind: :npc, char: char }
        step   = ::Harness::Dispatcher::Step.new(runner: "conversation", intent: cause, args: {})
        frame  = UNPROMPTED_FRAME.sub("<<CAUSE>>") { cause }

        emit, voicing_user = voice_one(context, input, step, player, v, roster,
                                       conversation_thread(context), nearby_places(context), wares_here(context),
                                       resolver, tcs, active, nil, frame: frame)
        prose = emit&.dig("dialogue", "prose").to_s.strip
        if emit.nil? || !emit["speak"] || prose.empty?
          @logger.info { "[Runner conversation] unprompted voicing declined for #{npc.name} (speak=#{emit && emit['speak'].inspect})" }
          transcript&.record_tool_calls(tcs)
          return nil
        end
        return nil unless apply_emit(resolver, context, scene, emit, v, player, {}, tcs)

        active&.mark_spoken!(npc.id)
        reflect_knowledge(context, v, emit, voicing_user)
        reevaluate_state(context, v, emit, voicing_user, active)
        transcript&.record_tool_calls(tcs)
        prose
      end

      private

      def voice_one(context, input, step, player, v, roster, thread, nearby, wares, resolver, tcs, active, contest = nil, frame: nil)
        you =
          if v[:kind] == :extra
            { "ambient" => true, "index" => v[:index], "desc" => v[:desc] }
          else
            npc_knowledge(resolver, v[:char], tcs, active, event_cap: EVENT_SUMMARY_CAP)
          end
        # The contest verdict rides in the TARGET's you-block — the dice have
        # ruled; the voicing renders the consequence, it does not re-judge.
        if contest && v[:kind] == :npc && v[:char]["id"] == contest[:target_id]
          you = you.merge("contest" => contest[:payload])
        end
        # EVERY polled NPC recalls: knowledge facts AND their own memories
        # through one relevance gate (the substantive/banter split is dead —
        # defensive design against a scarecrow that never materialized). The
        # gated-relevant memories (plus a small recency floor for continuity)
        # REPLACE the raw event dump; relevant facts land in `knowledge`.
        # Empty candidate pool → no gate call, so an empty world stays free.
        if v[:kind] == :npc && (npc_row = ::Npc.find_by(id: v[:char]["id"]))
          # Topic = input + planner intent. A thin input ("who?", "go on")
          # embeds as nearly nothing; the intent already describes what's
          # being sought — free query expansion, no extra LLM call.
          topic = [ input, step&.intent ].map { |s| s.to_s.strip }.reject(&:empty?).join(" — ")
          r = recall(context, npc_row, topic)
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
        invariant = {
          "player"          => { "id" => player.id, "name" => player.name },
          "player_input"    => input,
          "intent"          => step&.intent,
          "location"        => location_payload(context),
          "nearby_places"   => nearby
        }
        # Venue stock (invariant across speakers, absent outside shops): the
        # smith could not see her own racks and denied weapons standing next
        # to eight for-sale wares — the context-exposure class again.
        invariant["wares_here"] = wares if wares
        user = JSON.pretty_generate(invariant.merge(
          "exchange_so_far" => thread,
          "others_present"  => others,
          "you"             => you
        ))
        sent_user = "INPUT:\n#{user}"
        # The unprompted frame (initiative voicing) rides AFTER the payload so
        # the shared prefix stays cache-identical with normal voicings.
        sent_user = "#{sent_user}\n\n#{frame}" if frame
        who = v[:kind] == :npc ? v[:char]["name"] : "extra##{v[:index]}"
        emit = ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          raw = llm(context).complete(system: preamble, user: sent_user)
          e1  = parse_emit(raw)
          # One correction bounce: a malformed emit (bad JSON, or a speaker with
          # no line — the "pro"-for-"prose" class) goes back to the model with
          # the defect named. Same prefix, so the retry is KV-cache-hot.
          if (defect = emit_defect(e1))
            @logger.warn { "[Runner conversation] #{who} emit malformed (#{defect}) — retrying once" }
            raw = llm(context).complete(system: preamble, user: "#{sent_user}\n\n#{retry_tail(defect, raw)}")
            e1  = parse_emit(raw)
            if (still = emit_defect(e1))
              @logger.warn { "[Runner conversation] #{who} emit still malformed (#{still}) — dropped" }
            end
          end
          e1
        end
        # The exact user string is returned alongside the emit so reflection
        # can extend it byte-identically (KV-cache prefix reuse).
        emit ? [ emit, sent_user ] : nil
      rescue StandardError => e
        @logger.warn { "[Runner conversation] voice failed: #{e.class}: #{e.message}" }
        nil
      end

      # A defect worth a retry: unparseable output, or a declared speaker whose
      # emit carries nothing committable (no prose, no consequential field).
      def emit_defect(emit)
        return "not valid JSON" unless emit.is_a?(::Hash)
        dlg   = emit["dialogue"]
        prose = dlg.is_a?(::Hash) ? dlg["prose"].to_s.strip : ""
        if emit["speak"] && prose.empty? && !emit["resolve_call"] && !emit["ignorance"] && !emit["memorable"]
          return "\"speak\" is true but dialogue.prose is missing"
        end
        nil
      end

      def retry_tail(defect, raw)
        "--- RETRY ---\nYour previous output was rejected: #{defect}.\n" \
        "Previous output:\n#{raw}\n\nRe-emit the ENTIRE corrected JSON object now."
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
          "resolve=#{!emit['resolve_call'].nil?} ignorance=#{!emit['ignorance'].nil?} memorable=#{emit['memorable'].is_a?(Hash)} " \
          "thought=#{emit['thought'].to_s[0, 120].inspect}"
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
        # Mood and agenda ride EVERY turn now — the post-emit reevaluation
        # keeps them current, so they can't yank a spoken NPC back to a stale
        # seed (the reason they used to be dropped at mark_spoken). Mood leads
        # with the disposition-ladder word: the standing temperature toward
        # the player.
        {
          "id"          => char["id"],
          "name"        => char["name"],
          "subrole"     => char["subrole"],
          "lens"        => char["lens"],
          "personality" => (props["personality"] if props.is_a?(::Hash)),
          "appearance"  => ((props["appearance"] || props["physical"]) if props.is_a?(::Hash)),
          "mood"        => mood_line(active, char["id"]),
          "agenda"      => active&.agenda_for(char["id"]),
          "events"      => events
        }.compact
      end

      # "guarded — wiping the same spot on the bar, eyes on the door" — the
      # ladder word plus the living flavor line. Nil when there's nothing to
      # say (no seeded state and a neutral ladder).
      def mood_line(active, id)
        return nil unless active
        disp   = active.disposition_for(id)
        flavor = active.state_for(id)
        if flavor && disp != "neutral" then "#{disp} — #{flavor}"
        elsif flavor                   then flavor
        elsif disp != "neutral"        then disp
        end
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

      # For-sale stock anchored at the scene, with the settlement's mechanical
      # buy prices — nil anywhere without wares, so the payload key (and its
      # tokens) exists only inside an actual shop.
      def wares_here(context)
        loc = context.player_location
        return nil unless loc
        items = ::Item.where(location_id: loc.id).select { |i| i.properties.is_a?(::Hash) && i.properties["for_sale"] }
        return nil if items.empty?
        facts = ::Harness::Settlement::Facts.for(loc)
        items.map do |i|
          { "name"  => i.name,
            "price" => ::Harness::Economy::Pricing.buy_price(i, wealth: facts["wealth"], economic_basis: facts["economic_basis"]) }
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
        user    = "#{voicing_user}\n\n#{reflection_tail(prose)}"
        raw = ::Harness::CostTracker.in_subsystem(:knowledge_capture) do
          llm(context).complete(system: preamble, user: user)
        end
        payload = ::Harness::LLM::JsonResponse.parse(raw)
        # One correction bounce, mirroring voice_one's: the tail's schema
        # override is flaky on the compressed quant — when the model answers
        # in the dialogue shape (or garbage), re-ask once with the defect
        # named instead of dropping the claims outright.
        if (defect = reflection_defect(payload))
          @logger.warn { "[Runner conversation] reflection for #{speaker} #{defect} — retrying once" }
          raw = ::Harness::CostTracker.in_subsystem(:knowledge_capture) do
            llm(context).complete(system: preamble, user: "#{user}\n\n#{reflection_retry_tail(defect, raw)}")
          end
          payload = ::Harness::LLM::JsonResponse.parse(raw)
          if (still = reflection_defect(payload))
            @logger.warn { "[Runner conversation] reflection for #{speaker} #{still} on retry — claims dropped" }
            return
          end
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

      # POST-EMIT STATE REEVALUATION — the "taking stock" pass. Third call on
      # the speaker's still-hot voicing prefix (after the emit and reflection —
      # the shared prefix is KV-cached, only the tail is new compute): did this
      # exchange move the speaker's disposition (ONE ladder step max), refresh
      # their mood line, or conclude their agenda? Personality is INPUT only —
      # it conditions the shift, never changes. The contest verdict, when one
      # fired, is already in the voicing payload — the eval feels it through
      # personality rather than re-judging it. A garbage emit is skipped
      # outright (held state is always safe), no retry bounce. Speakers only.
      def reevaluate_state(context, v, emit, voicing_user, active)
        return unless active
        prose = emit.dig("dialogue", "prose").to_s.strip
        return if prose.empty? || voicing_user.nil?
        id = v[:char]["id"]

        user = "#{voicing_user}\n\n#{reevaluation_tail(prose)}"
        raw = ::Harness::CostTracker.in_subsystem(:mood_reevaluation) do
          llm(context).complete(system: preamble, user: user)
        end
        taking = ::Harness::LLM::JsonResponse.parse(raw)
        unless taking.is_a?(::Hash) && taking.key?("disposition")
          @logger.warn { "[Runner conversation] reevaluation for #{v[:char]['name']} unparseable — state held" }
          return
        end

        active.shift_disposition!(id, taking["disposition"]) if %w[warmer colder].include?(taking["disposition"])
        active.update_state!(id, taking["mood"].strip) if taking["mood"].is_a?(::String) && !taking["mood"].strip.empty?
        active.clear_agenda!(id) if %w[resolved abandoned].include?(taking["agenda"]) && active.agenda_for(id)

        @logger.info do
          "[Runner conversation] #{v[:char]['name']} takes stock: disposition=#{taking['disposition']}" \
            " (now #{active.disposition_for(id)}) mood #{taking['mood'] ? 'refreshed' : 'held'}" \
            " agenda=#{taking['agenda'] || 'pursue'}"
        end
      rescue ::StandardError => e
        @logger.warn { "[Runner conversation] reevaluation failed for #{v[:char]['name']}: #{e.class}: #{e.message}" }
      end

      def reevaluation_tail(prose)
        @reevaluation_template ||= File.read(REEVALUATION_PROMPT_PATH)
        @reevaluation_template.sub("<<SAID>>") { prose }
      end

      # <<...>> markers are runtime substitutions owned by THIS runner —
      # deliberately not {{...}}, which is Prompts::Preamble's vocabulary
      # namespace (its integration spec rejects unexpanded {{ in prompt files).
      def reflection_tail(prose)
        @reflection_template ||= File.read(REFLECTION_PROMPT_PATH)
        @reflection_template.sub("<<SAID>>") { prose }
      end

      def reflection_defect(payload)
        return "unparseable" unless payload.is_a?(::Hash)
        if payload.key?("speak") && !(payload.key?("facts") || payload.key?("people") || payload.key?("places"))
          return "answered in DIALOGUE schema"
        end
        nil
      end

      def reflection_retry_tail(defect, raw)
        "--- RETRY ---\nYour previous output was rejected: #{defect}.\nPrevious output:\n#{raw}\n\n" \
        "The dialogue turn is OVER. Output ONLY the world-memory JSON — no \"thought\", no \"speak\" — beginning with {\"facts\":"
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
