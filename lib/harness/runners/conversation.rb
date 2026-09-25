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
    # (resolve_call → resolve), and a
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
      LEDGER_STRUCK_PATH     = Rails.root.join("lib/harness/prompts/ledger_struck.txt")
      LEDGER_TERMS_PATH      = Rails.root.join("lib/harness/prompts/ledger_terms.txt")
      LEDGER_DELIVERED_PATH  = Rails.root.join("lib/harness/prompts/ledger_delivered.txt")
      LEDGER_DISCHARGED_PATH = Rails.root.join("lib/harness/prompts/ledger_discharged.txt")
      STOCK_INNER_PATH = Rails.root.join("lib/harness/prompts/taking_stock_inner.txt")
      STOCK_HANDS_PATH = Rails.root.join("lib/harness/prompts/taking_stock_hands.txt")
      ACT_PROMPT_PATH          = Rails.root.join("lib/harness/prompts/conversation_act.txt")
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
      # SANITY CEILING on the voicing emit, not a budget: the largest of 989
      # successful emits was 252 tokens. A grammar loop (see VOICING_SCHEMA)
      # otherwise runs to the adapter's 8192 and costs ~100 s per speaker.
      VOICING_MAX_TOKENS = 1024
      PLACES_CAP  = 12
      RECALL_CAP  = 8

      def run(context:, scene:, input:, step:)
        present = Array(scene["present_characters"])
        # An empty room is an honest silence, not a stale plan: re-planned, the
        # same words drew the same talk step, the cap was spent and the wait
        # behind it never ran (hands run 8 t19, the Granary after Yngvar left).
        if present.empty?
          @logger.info { "[Runner conversation] no one here at all — silence" }
          return Outcome.new(tool_calls: [ tool_call("conversation_silence", {}, { "nobody_spoke" => true, "nobody_here" => true }) ], scene_dirty: false, status: :ok)
        end

        player = ::Player.first
        return redispatch("no player row") unless player

        resolver = resolver_for(context)
        active   = context.active_scene
        tcs      = []
        thread   = conversation_thread(context)
        roster   = present.map { |c| { "name" => c["name"], "subrole" => c["subrole"] } }
        nearby   = nearby_places(context)
        wares    = wares_here(context)
        step     = addressed_step(context, input, step, present, thread)
        # The contest, judged before anyone is voiced: kind and party, the
        # binding, the target's consent, then the dice or a standing verdict
        # re-served (open_contest). nil is plain talk.
        contest  = open_contest(context, input, player, present, active, resolver, tcs, addressed_id: step.args["with_id"])

        spoken     = 0
        parsed_any = false
        tails      = []
        # No bystander frame. Telling an un-addressed pollee that someone had
        # already answered did not stop the restate ("…same as Solveig said",
        # 2026-09-12) and once told the person being asked that no one had
        # addressed them. The exchange itself is what a character reads; a
        # dim chime-in is a character being dim, not the system (user ruling).
        spoke_ids  = []
        order = poll_order(present, step, active)
        # Recall is for SPEECH: when the input names someone, un-addressed
        # bystanders skip the recall gate (they keep their raw recent events —
        # a chime-in grounds in the exchange, not deep lore). An open-mic
        # input (nobody named) keeps recall for everyone: any of them may be
        # the addressee. Contest targets always recall.
        any_addressed = order.any? { |v| v[:addressed] }
        if order.empty?
          # Nobody to voice: no character here ("approach the bar" in a
          # keeperless tavern, items run 7).
          # An honest silence, not a redispatch — the executor re-planned the
          # same conversation step four times and rendered "emit unparseable".
          @logger.info { "[Runner conversation] no one here to answer — silence" }
          tcs << tool_call("conversation_silence", {}, { "nobody_spoke" => true, "nobody_here" => true })
          return Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
        end
        order.each do |v|
          break if spoken >= MAX_SPEAKERS
          is_target = contest && v[:kind] == :npc && v[:char]["id"] == contest[:target_id]
          recall_gate = !any_addressed || v[:addressed] || is_target
          # THE CHIME-IN GATE (C0): once the addressed line exists, a bystander
          # is asked one small question — do you have something of your own
          # to add — before the whole voicing is spent on them. Open-mic
          # turns (nobody addressed) poll everyone as before.
          if any_addressed && !v[:addressed] && !is_target && v[:kind] == :npc
            next unless chime_in?(context, v, input, order, tcs, active)
          end
          emit, voicing_user, fed = voice_one(context, input, step, player, v, roster, thread_with_current(thread, input, tcs), nearby, wares, resolver, tcs, active, contest,
                                         frame: verdict_frame(contest, v), recall_gate: recall_gate)
          next unless emit
          parsed_any = true
          applied = apply_emit(resolver, context, scene, emit, v, player, tcs, input: input, contest: contest)
          # The silent snub: a decliner's visible shift still lands on the
          # scene — no line of theirs carries it, so perception voices it
          # (the doing change reaches the eyes as a shift).
          if !applied && v[:kind] == :npc && emit["speak"] == false && active &&
             emit["doing"].is_a?(::String) && !emit["doing"].strip.empty? &&
             emit["doing"].strip != active.doing_for(v[:char]["id"]).to_s
            active.update_doing!(v[:char]["id"], emit["doing"].strip)
          end
          if applied
            spoken += 1
            spoke_ids << v[:char]["id"]
            # First speaking turn consumed the seeded mood/agenda; from now on the
            # thread carries this NPC (npc_knowledge drops the frozen self-state).
            active&.mark_spoken!(v[:char]["id"]) if v[:kind] == :npc
            tails << { v: v, emit: emit, fed: fed, contest: contest }
          end
          break if combat_started?(tcs)
        end
        # The live thread: whoever spoke this turn is the presumptive addressee
        # of the next unnamed line. Replaced whole (scene arrays are never
        # mutated); a silent turn leaves it standing.
        active.last_speakers = spoke_ids.compact if active && spoke_ids.any?
        run_tails(context, tails, active, tcs)

        return redispatch("conversation emit unparseable", tcs) unless parsed_any
        # Everyone declined (or was suppressed): mark the turn as an explicit
        # NON-response so narration renders the silence instead of filling the
        # vacuum with invented dialogue (the model's strongest prior on a
        # charged line is to write the reply itself).
        tcs << tool_call("conversation_silence", {}, { "nobody_spoke" => true }) if spoken.zero?
        # An attack step is a hard terminator, exactly as the combat runner's.
        Outcome.new(tool_calls: tcs, scene_dirty: false, status: combat_started?(tcs) ? :combat : :ok)
      end

      private

      # The per-speaker TAIL — reflection (two judges) and taking-stock — runs
      # after the LAST speaker is voiced, never between speakers. Between them
      # it fed speaker B the row just minted from speaker A's line on top of
      # the line itself in exchange_so_far: the same-turn echo amplifier
      # (Dunstan reciting Kenric, 2026-09-12). Nothing a later speaker
      # consumes depends on the tail, and the hearer set is the same room
      # either way. The old placement bought a hot llama.cpp prefix for the
      # judges; the hosted target has no prefix cache.
      def run_tails(context, tails, active, tcs = nil)
        tails.each do |t|
          v = t[:v]
          reflect_knowledge(context, v, t[:emit], t[:fed], tool_calls: tcs)
          reevaluate_state(context, v, t[:emit], active, t[:fed], tcs, contest: t[:contest])
        end
      end

      # Poll order: the character the plan ADDRESSED (A1's with_id) goes
      # FIRST and is marked addressed — so an addressee is always asked before
      # the two-speaker cap can be filled by chime-ins. Nobody addressed is
      # the room: whoever spoke last turn is polled first and carries
      # `addressed` (a follow-up question in an exchange one person was
      # carrying went unanswered because both present NPCs read "no name" as
      # "not addressed", 2026-09-12). Painted extras are scenery, never
      # speakers (ruling 2026-09-25: no person is an extra). This is poll
      # ORDER, not a speech ruling — each character still self-decides
      # whether it speaks.
      def poll_order(present, step, active = nil)
        with_id = step&.args&.dig("with_id")
        npcs = present.map { |c| { kind: :npc, char: c } }
        named, rest = npcs.partition { |v| with_id.is_a?(::Integer) && v[:char]["id"] == with_id }
        named.each { |v| v[:addressed] = true }
        if named.empty? && active
          carry, rest = rest.partition { |v| active.spoke_last?(v[:char]["id"]) }
          carry.each { |v| v[:continuing] = true }
          rest = carry + rest
        end
        named + rest
      end

      CHIME_PROMPT_PATH = Rails.root.join("lib/harness/prompts/chime_in.txt")
      CHIME_SCHEMA = {
        "type" => "object",
        "properties" => { "reasoning" => { "type" => "string" }, "chime_in" => { "type" => "boolean" } },
        "required" => %w[reasoning chime_in],
        "additionalProperties" => false
      }.freeze

      # A bystander's one question, on one line of who they are, the player's
      # words to someone else, what was said in answer so far, and the last
      # thing they said themselves. In the hands runs, 15 of 85 logged
      # bystander voicings spoke, most of them seconding ("Aslaug's right",
      # "He's right — one coin"), at a full voicing call each.
      def chime_in?(context, v, input, order, tcs, active)
        id    = v[:char]["id"]
        props = ::Npc.find_by(id: id)&.properties
        you   = { "name" => v[:char]["name"], "subrole" => v[:char]["subrole"],
                  "personality" => (props["personality"] if props.is_a?(::Hash)),
                  "mood" => mood_line(active, id), "agenda" => active&.agenda_for(id), "doing" => active&.doing_for(id),
                  "debts" => debts_for(id, context.game_time),
                  "settled" => (active&.contest_ledger || {}).filter_map { |k, p| p["verdict"] if p.is_a?(::Hash) && k.to_s.start_with?("#{id}:") }.presence }.compact
        addressed = order.find { |o| o[:addressed] }
        payload = {
          "you"            => you,
          "player_said"    => input,
          "addressed"      => addressed && addressed[:char]["name"],
          "said_this_turn" => Array(tcs).filter_map { |tc| tc.dig("args", "details") if tc["name"] == "propose_event" && tc.dig("result", "staged") },
          "you_said_last"  => (active&.last_lines || {})[id]
        }.compact
        raw = ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          llm(context).complete(system: (@chime_prompt ||= File.read(CHIME_PROMPT_PATH)), user: "INPUT:\n#{JSON.pretty_generate(payload)}", max_tokens: JUDGE_MAX_TOKENS, schema: CHIME_SCHEMA, temperature: 0, thinking: false)
        end
        out = parse_emit(raw)
        yes = out.is_a?(::Hash) && out["chime_in"] == true
        @logger.info { "[Runner conversation] #{v[:char]['name']} #{yes ? 'has something to add' : 'holds their tongue'} (#{out.is_a?(::Hash) ? out['reasoning'] : 'unparseable'})" }
        yes
      rescue StandardError => e
        @logger.warn { "[Runner conversation] chime-in gate failed for #{v[:char]['name']}: #{e.class}: #{e.message}" }
        false
      end

      # WHOM THE WORDS ARE FOR — one narrow judge on the room as it stands
      # (after any movement step) and the last exchanges; its answer replaces
      # the plan's binding for this step. The planner, routing and decomposing
      # in the same call, bound the right person on 6 of 13 unnamed
      # continuations in hands runs 6–7 ("Fair enough on the locket. What
      # about that mace" bound no one and nobody answered; "What else have
      # you got" went to the other trader); this judge, 12 of 13 on the same
      # turns, 61 of 62 over all, and no one on 10 of 10 lines for the room.
      # One candidate is no question; a failed call leaves the plan's binding.
      ADDRESSEE_PROMPT_PATH = Rails.root.join("lib/harness/prompts/addressee.txt")
      ADDRESSEE_SCHEMA = {
        "type" => "object",
        "properties" => { "reasoning" => { "type" => "string" }, "with_id" => { "type" => %w[integer null] } },
        "required" => %w[reasoning with_id],
        "additionalProperties" => false
      }.freeze
      ADDRESSEE_THREAD = 4

      def addressed_step(context, input, step, present, thread)
        return step if present.size < 2
        # How each one looks rides along: with name and trade alone the judge
        # knew whom the words were for and had no id to answer with (run 8 t25).
        looks = looks_for(present.map { |c| c["id"] })
        payload = {
          "player_said" => input,
          "present"     => present.map { |c| { "id" => c["id"], "name" => c["name"], "trade" => c["subrole"], "looks" => looks[c["id"]] }.compact },
          "exchange"    => thread.last(ADDRESSEE_THREAD)
        }
        out = contest_judge(context, ADDRESSEE_PROMPT_PATH, ADDRESSEE_SCHEMA, payload) or return step
        with_id = out["with_id"]
        if with_id && present.none? { |c| c["id"] == with_id }
          @logger.warn { "[Runner conversation] addressee judge named no one here (#{out.slice('with_id').inspect}) — the plan's binding stands" }
          return step
        end
        @logger.info { "[Runner conversation] addressee: #{with_id ? "id #{with_id}" : 'the room'} (plan had #{step.args.slice('with_id').inspect}) — #{out['reasoning']}" }
        step.dup.tap { |s| s.args = step.args.except("with_id").merge({ "with_id" => with_id }.compact) }
      end


      # THE CONTEST — judged before anyone is voiced, by three narrow calls,
      # replacing the planner's contest binding and the voicing's `guarded`
      # flag (the planner bound a press on 55 of 114 talk steps in the hands
      # runs, nearly all answered freely; swaps and payments came bound as
      # haggles; a coin toss rolled as dexterity). KIND: plain talk, or a
      # press, haggle, game or wager, with whom, and whether it is the same
      # ask a standing verdict already settled (the re-serve: you don't get
      # to ask the same question harder). BINDING, per kind: the ware and
      # the offer; the faculty, chance for a toss; both stakes; the ability
      # invoked. CONSENT: the target's own read — would they withhold it, do
      # they play. Then the dice, and the target is voiced once under the
      # verdict. Fail-open: nobody present, nothing bindable, a roll error →
      # plain talk. The scene ledger stores verdicts; it no longer gates.
      SOCIAL_ABILITY_KINDS = %w[control utility].freeze
      BOUND_STATS   = %w[strength dexterity constitution intelligence wisdom charisma].freeze
      FACULTIES     = (BOUND_STATS + %w[chance]).freeze
      STAKE_IS  = %w[coins listed_thing unlisted_thing nothing].freeze
      CONTEST_KINDS = %w[none press haggle game wager].freeze
      CONTEST_KIND_PATH    = Rails.root.join("lib/harness/prompts/contest_kind.txt")
      CONTEST_CONSENT_PATH = Rails.root.join("lib/harness/prompts/contest_consent.txt")
      CONTEST_BIND_PATHS   = { "press"  => Rails.root.join("lib/harness/prompts/contest_press.txt"),
                               "haggle" => Rails.root.join("lib/harness/prompts/contest_haggle.txt"),
                               "game"   => Rails.root.join("lib/harness/prompts/contest_game.txt"),
                               "wager"  => Rails.root.join("lib/harness/prompts/contest_wager.txt") }.freeze
      # Grammars (property order is grammar: `reasoning` first, all required).
      CONTEST_KIND_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "kind"      => { "type" => "string", "enum" => CONTEST_KINDS },
          "with_id"   => { "type" => %w[integer null] },
          "same_as"   => { "type" => %w[integer null] }
        },
        "required" => %w[reasoning kind with_id same_as],
        "additionalProperties" => false
      }.freeze
      CONTEST_BIND_SCHEMAS = {
        "press"  => { "type" => "object",
                      "properties" => { "reasoning" => { "type" => "string" }, "ability_id" => { "type" => %w[string null] } },
                      "required" => %w[reasoning ability_id], "additionalProperties" => false },
        "haggle" => { "type" => "object",
                      "properties" => { "reasoning" => { "type" => "string" }, "ware_id" => { "type" => %w[integer null] }, "offer" => { "type" => %w[integer null] } },
                      "required" => %w[reasoning ware_id offer], "additionalProperties" => false },
        "game"   => { "type" => "object",
                      "properties" => { "reasoning" => { "type" => "string" }, "faculty" => { "type" => "string", "enum" => FACULTIES } },
                      "required" => %w[reasoning faculty], "additionalProperties" => false },
        # What each side puts up is classed BEFORE it is bound: "four coins
        # against your blade", the blade on no list, came back as a coin
        # counter-stake the judge invented (hands run 9 t27). A thing named
        # that is not listed voids the wager instead.
        "wager"  => { "type" => "object",
                      "properties" => { "reasoning" => { "type" => "string" },
                                        "stake_is" => { "type" => "string", "enum" => STAKE_IS }, "against_is" => { "type" => "string", "enum" => STAKE_IS },
                                        "faculty" => { "type" => "string", "enum" => FACULTIES },
                                        "stake_coins" => { "type" => %w[integer null] }, "stake_item_id" => { "type" => %w[integer null] },
                                        "against_coins" => { "type" => %w[integer null] }, "against_item_id" => { "type" => %w[integer null] } },
                      "required" => %w[reasoning stake_is against_is faculty stake_coins stake_item_id against_coins against_item_id], "additionalProperties" => false }
      }.freeze
      CONTEST_CONSENT_SCHEMA = {
        "type" => "object",
        "properties" => { "reasoning" => { "type" => "string" }, "contest" => { "type" => "boolean" } },
        "required" => %w[reasoning contest],
        "additionalProperties" => false
      }.freeze
      CONTEST_SAMPLING = { temperature: 0, thinking: false }.freeze

      def open_contest(context, input, player, present, active, resolver, tcs, addressed_id: nil)
        standing  = standing_entries(active, present)
        addressed = present.find { |c| c["id"] == addressed_id }
        looks     = looks_for(present.map { |c| c["id"] })
        payload   = { "player_said" => input,
                      "present"     => present.map { |c| { "id" => c["id"], "name" => c["name"], "trade" => c["subrole"], "looks" => looks[c["id"]] }.compact },
                      "standing"    => standing.map { |e| e.slice("n", "with", "action", "verdict") } }
        # Whom the router said the words are for. The kind judge, shown only
        # the words, pressed Bertha's cheese on Herewald, whose agenda was
        # cheese (run 7 t29); the router owns the addressee (A1), and when
        # the two disagree the router's choice is the contest's party.
        payload["addressed"] = addressed.slice("id", "name") if addressed
        kind = contest_judge(context, CONTEST_KIND_PATH, CONTEST_KIND_SCHEMA, payload)
        return nil unless kind && CONTEST_KINDS.include?(kind["kind"]) && kind["kind"] != "none"
        target = present.find { |c| c["id"] == kind["with_id"] }
        if addressed && target && target["id"] != addressed["id"]
          @logger.info { "[Runner conversation] contest judge chose #{target['name']} but the words are for #{addressed['name']} — the addressee is the party" }
          target = addressed
        end
        target ||= addressed
        unless target
          @logger.info { "[Runner conversation] contest #{kind['kind']} with no one present (with_id=#{kind['with_id'].inspect}) — plain talk" }
          return nil
        end
        @logger.info { "[Runner conversation] contest judge: #{kind['kind']} with #{target['name']} (#{kind['reasoning']})" }
        if (entry = standing.find { |e| e["n"] == kind["same_as"] }) && entry["with_id"] == target["id"]
          return reserve_standing(entry, player, target, tcs)
        end
        contest = bind_contest(context, kind["kind"], input, player, target)
        return nil unless contest
        return settle_contest!(contest, player, resolver, tcs, active) if contest[:void]
        return declined(contest, target, tcs) if contest[:kind] != "haggle" && !consents?(context, contest, input, target, active)
        settle_contest!(contest, player, resolver, tcs, active)
      end

      # One narrow judge call at zero temperature; nil when unparseable.
      def contest_judge(context, path, schema, payload)
        @contest_prompts ||= {}
        system = (@contest_prompts[path] ||= File.read(path))
        raw = ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          llm(context).complete(system: system, user: "INPUT:\n#{JSON.pretty_generate(payload)}", schema: schema, max_tokens: JUDGE_MAX_TOKENS, **CONTEST_SAMPLING)
        end
        out = parse_emit(raw)
        return out if out.is_a?(::Hash) && (schema["properties"].keys - %w[reasoning]).any? { |k| out.key?(k) }
        @logger.warn { "[Runner conversation] #{File.basename(path, '.txt')} unparseable — plain talk" }
        nil
      rescue StandardError => e
        @logger.warn { "[Runner conversation] #{File.basename(path, '.txt')} failed: #{e.class}: #{e.message}" }
        nil
      end

      # The scene's settled contests with people still here, numbered for
      # the kind judge's `same_as`.
      def standing_entries(active, present)
        (active&.contest_ledger || {}).filter_map do |key, payload|
          next unless payload.is_a?(::Hash)
          id  = key.to_s.split(":").first.to_i
          who = present.find { |c| c["id"] == id }
          next unless who
          { "key" => key, "with_id" => id, "with" => who["name"], "action" => payload["action"] || "press #{who['name']}", "verdict" => payload["verdict"], "payload" => payload }
        end.each_with_index.map { |e, i| e.merge("n" => i + 1) }
      end

      # The same ask again meets the standing verdict as a FACT in the
      # payload (and, when the player had won, the yield frame again — a
      # fact alone left the winner's target silent, tester run 4 t7).
      # Framed twice with the HOLD, the target re-emitted its refusal word
      # for word (probe 9); the exchange already shows what it said. The
      # re-serve is recorded and rendered like the roll it repeats.
      def reserve_standing(entry, player, target, tcs)
        prior = entry["payload"]
        @logger.info { "[Runner conversation] contest #{entry['key']} settled this scene (#{prior['verdict']}) — the same ask again, the verdict stands" }
        verdict  = [ prior["verdict"], "pressed again, the verdict stands" ].compact.join("; ")
        standing = prior.merge("verdict" => verdict, "repeat" => true)
        tcs << tool_call("contest_standing", { "actor_id" => player.id, "target_id" => target["id"], "action" => entry["action"] }, standing)
        { target_id: target["id"], target: target, key: entry["key"], kind: prior["kind"], args: {}, payload: standing }
      end

      # The prepared contest: who, what kind, how it would roll — nothing
      # rolled yet. nil when nothing binds (plain talk).
      def bind_contest(context, kind, input, player, target)
        base = { target_id: target["id"], target: target, kind: kind, ability: nil, stat: nil, faculty: nil, haggle: nil, wager: nil, void: nil, told: nil, payload: nil }
        args = { "actor_id" => player.id, "target_id" => target["id"] }
        case kind
        when "press"
          # SOCIAL-COMPATIBLE KINDS ONLY: resolve executes a bound ability's
          # REAL mechanics — a damage-kind bolt "backing" a business pitch
          # deals actual HP and burns a use (the Idunn-at-14/20 incident).
          socials = Array(player.abilities).select { |a| SOCIAL_ABILITY_KINDS.include?(a["effect_kind"].to_s) }
          ability = nil
          if socials.any?
            b = contest_judge(context, CONTEST_BIND_PATHS["press"], CONTEST_BIND_SCHEMAS["press"],
                              { "player_said" => input, "with" => target["name"], "abilities" => socials.map { |a| { "id" => a["id"], "name" => a["name"] } } })
            ability = socials.find { |a| a["id"].to_s == b["ability_id"].to_s } if b && b["ability_id"]
          end
          args["action"] = "press #{target['name']}"
          if ability
            args["ability_name"] = ability["name"]   # resolve's lookup matches on display name, not id
          else
            args["stat"] = "charisma"
            args["target_stat"] = "wisdom"
          end
          base.merge(key: "#{target['id']}:#{ability ? ability['id'] : 'social'}", ability: ability, args: args)
        when "haggle"
          # Only the TARGET's wares: a press over "the tallow" against Wystan
          # bound to Aelric's jar on the next table (items run 5, t30).
          wares = target_wares(target, player)
          return nil if wares.empty?
          b = contest_judge(context, CONTEST_BIND_PATHS["haggle"], CONTEST_BIND_SCHEMAS["haggle"],
                            { "player_said" => input, "with" => target["name"],
                              "wares" => wares.map { |i| { "id" => i.id, "name" => i.name, "asking" => ::Harness::Tools::QueryScene.shop_price(i, player.location) } } })
          item  = b && wares.find { |i| i.id == b["ware_id"] }
          offer = b && b["offer"]
          return nil unless item && offer.is_a?(::Integer) && offer > 0
          asking = ::Harness::Tools::QueryScene.shop_price(item, player.location)
          if offer >= asking
            @logger.info { "[Runner conversation] haggle offer #{offer} meets the asking #{asking} for #{item.name} — plain talk" }
            return nil
          end
          args["action"] = "haggle with #{target['name']} over the #{item.name}"
          args["stat"] = "charisma"
          args["target_stat"] = "wisdom"
          base.merge(key: "#{target['id']}:haggle:#{item.id}", haggle: { item: item, offer: offer, asking: asking }, args: args)
        when "game", "wager"
          payload = { "player_said" => input, "with" => target["name"] }
          if kind == "wager"
            payload["carried"] = player.items.map { |i| { "id" => i.id, "name" => i.name } }
            payload["wares"]   = (target_wares(target, player) + target_carried(target)).map { |i| { "id" => i.id, "name" => i.name } }
          end
          b = contest_judge(context, CONTEST_BIND_PATHS[kind], CONTEST_BIND_SCHEMAS[kind], payload)
          faculty = b && FACULTIES.include?(b["faculty"]) ? b["faculty"] : nil
          return nil unless faculty
          # "I'd wager you've a knife on you" names no stake on either side:
          # a turn of phrase, not a bet — it is the ask it carries, a press.
          if kind == "wager" && %w[stake_coins stake_item_id against_coins against_item_id].none? { |k| b[k] }
            @logger.info { "[Runner conversation] wager with nothing staked on either side — read as a press" }
            return bind_contest(context, "press", input, player, target)
          end
          # A game of chance flips the engine's own coin; anything else is an
          # opposed roll of the same faculty on both sides.
          stat = faculty == "chance" ? nil : faculty
          if stat
            args["stat"] = stat
            args["target_stat"] = stat
          end
          contest = base.merge(key: "#{target['id']}:#{faculty}", stat: stat, faculty: faculty, args: args)
          if kind == "wager"
            w = wager_stakes(b, target, player)
            if (reason = w[:void])
              @logger.info { "[Runner conversation] wager void — #{reason}" }
              return contest.merge(void: reason, told: w[:told], key: nil, args: {})
            end
            contest[:wager] = w
            args["action"] = "wager with #{target['name']}: #{stake_words(w[:stake])} against #{stake_words(w[:against])}"
          else
            args["action"] = "#{faculty == 'chance' ? 'a game of chance' : "a game of #{faculty}"} with #{target['name']}"
          end
          contest
        end
      end

      # CONSENT — the target's own read, before any roll: for a press, is
      # what is asked something they would not freely give; for a game or
      # wager, do they play. A press given freely is plain talk; a game
      # declined is a receipt and a fact for the voice.
      def consents?(context, contest, input, target, active)
        npc   = ::Npc.find_by(id: target["id"])
        props = npc&.properties
        you   = { "name" => target["name"], "subrole" => target["subrole"],
                  "personality" => (props["personality"] if props.is_a?(::Hash)),
                  "disposition" => active&.disposition_for(target["id"]), "mood" => active&.state_for(target["id"]),
                  "agenda" => active&.agenda_for(target["id"]), "coins" => npc&.coins.to_i,
                  "debts" => debts_for(target["id"], context.game_time) }.compact
        terms = if contest[:wager] then "#{stake_words(contest[:wager][:stake])} against #{stake_words(contest[:wager][:against])}, a game of #{contest[:faculty]}"
                elsif contest[:faculty] then "a game of #{contest[:faculty]}"
                end
        c = contest_judge(context, CONTEST_CONSENT_PATH, CONTEST_CONSENT_SCHEMA,
                          { "you" => you, "player_said" => input, "kind" => contest[:kind], "terms" => terms }.compact)
        yes = c.is_a?(::Hash) && c["contest"] == true
        @logger.info { "[Runner conversation] #{target['name']} #{yes ? 'takes on' : 'does not take on'} the #{contest[:kind]} (#{c && c['reasoning']})" }
        yes
      end

      def declined(contest, target, tcs)
        first = first_name(target)
        if contest[:kind] == "press"
          @logger.info { "[Runner conversation] #{target['name']} would give it freely — no press, plain talk" }
          return nil
        end
        tcs << tool_call("wager_void", { "target_id" => target["id"] }, { "reason" => "#{first} won't play", "target_name" => target["name"] })
        contest.merge(payload: { "kind" => contest[:kind], "verdict" => "#{first} declined the game — nothing was played" })
      end

      # Wares for sale here under this seller's name, plus the house's own
      # stock (no seller recorded), which its staff sell.
      # What the other party has on them, by row — a stake as good as a ware.
      def target_carried(target)
        ::Item.where(character_id: target["id"]).order(:id).to_a
      end

      def target_wares(target, player)
        loc = player.location
        return [] unless loc
        ::Item.where(location_id: loc.id).select { |i|
          props = i.properties.is_a?(::Hash) ? i.properties : {}
          props["for_sale"] && (props["seller_id"] ? props["seller_id"] == target["id"] : true)
        }
      end

      # Stakes bound to the contest (items runs 6–8: conditional debt rows at
      # agreement, a payout that depended on the voice's hands, item stakes that
      # never moved). The binder names each side's stake by id or coins from
      # its own payload; the engine checks the means and settles on the
      # verdict — the winner takes the other side's stake, nothing is owed.
      # Both sides bind or nothing does: a one-sided wager risks something
      # against nothing, or nothing against something (user, 2026-09-15:
      # "fail instantly when it has no target to bind to"). A void carries
      # its reason — the player reads it on the receipt, the target reads it
      # as a fact and may bring the thing out (the act judge binds it) or say no.
      def wager_stakes(w, target, player)
        loc   = player.location
        first = first_name(target)
        # The player's side of a void is worded twice: "you" on the receipt,
        # by name in the target's payload — fed "you don't have 50 coins",
        # Dunstan answered that his till was short (items run 9, t31).
        me    = player.name.to_s.split.first
        stake = if w["stake_is"] == "unlisted_thing"
                  { void: "you carry no such thing to stake", told: "#{me} carries no such thing to stake" }
                elsif w["stake_item_id"].is_a?(::Integer)
                  item = ::Item.find_by(id: w["stake_item_id"], character_id: player.id)
                  item ? { item: item } : { void: "you carry no such thing to stake", told: "#{me} carries no such thing to stake" }
                elsif w["stake_coins"].is_a?(::Integer) && w["stake_coins"] > 0
                  if player.coins.to_i < w["stake_coins"]
                    { void: "you don't have #{w['stake_coins']} coins to stake", told: "#{me} doesn't have #{w['stake_coins']} coins to stake" }
                  else
                    { coins: w["stake_coins"] }
                  end
                else
                  { void: "nothing of yours was staked", told: "nothing of #{me}'s was staked" }
                end
        npc = ::Character.find_by(id: target["id"])
        against = if w["against_is"] == "unlisted_thing"
                    { void: "#{first} has no such thing here to stake" }
                  elsif w["against_item_id"].is_a?(::Integer) && loc
                    item  = ::Item.find_by(id: w["against_item_id"])
                    props = item&.properties.is_a?(::Hash) ? item.properties : {}
                    theirs = item && ((item.location_id == loc.id && props["for_sale"] && props["seller_id"] == target["id"]) || item.character_id == target["id"])
                    theirs ? { item: item } : { void: "#{first} has no such thing to stake" }
                  elsif w["against_coins"].is_a?(::Integer) && w["against_coins"] > 0 && npc
                    # A stake is what they can put up: Miron had one coin against two (items run 8, t28).
                    have = [ w["against_coins"], npc.coins.to_i ].min
                    have > 0 ? { coins: have } : { void: "#{first} has no coin to stake" }
                  else
                    { void: "nothing of #{first}'s was staked" }
                  end
        if (reason = stake[:void] || against[:void])
          return { void: reason, told: stake[:told] || against[:told] || reason }
        end
        { stake: stake, against: against }
      end

      def stake_words(side)
        return "nothing" unless side
        side[:item] ? "the #{side[:item].name}" : "#{side[:coins]} coins"
      end

      # The stakes change hands on the verdict. Coins go through
      # transfer_coins (its event and receipt line); a won ware leaves the
      # table for the player's hands; a lost carried thing lands on the
      # winner's table, for sale under their name — buy it back, or steal it.
      def settle_wager!(w, player_won, player, target, resolver, tcs)
        side, from, to = player_won ? [ w[:against], target, player ] : [ w[:stake], player, target ]
        return nil unless side
        if side[:coins]
          execute_tool(resolver, "transfer_coins", { "from_id" => from["id"] || from.id, "to_id" => to["id"] || to.id, "amount" => side[:coins], "reason" => "the wager" }, into: tcs)
        else
          item  = side[:item]
          props = item.properties.is_a?(::Hash) ? item.properties.dup : {}
          if player_won
            %w[for_sale seller_id haggled_price].each { |k| props.delete(k) }
            item.update!(character_id: player.id, location_id: nil, properties: props)
          else
            props["for_sale"]  = true
            props["seller_id"] = target["id"]
            props.delete("haggled_price")
            item.update!(character_id: nil, location_id: player.location_id, properties: props)
          end
          tcs << tool_call("wager_stake", { "item_id" => item.id, "target_id" => target["id"] },
                           { "item_name" => item.name, "player_won" => player_won, "target_name" => target["name"] })
        end
        stake_words(side)
      end

      # Rolls a prepared contest and fills contest[:payload]. Returns the
      # contest; payload stays nil when the roll itself failed (the
      # character is then voiced plainly).
      def settle_contest!(contest, player, resolver, tcs, active)
        target  = contest[:target]
        key     = contest[:key]
        ability = contest[:ability]
        stat    = contest[:stat]

        if (reason = contest[:void])
          tcs << tool_call("wager_void", { "target_id" => target["id"] }, { "reason" => reason, "target_name" => target["name"] })
          contest[:payload] = { "kind" => "wager", "verdict" => "no wager was set — #{contest[:told] || reason}" }
          return contest
        end

        if contest[:faculty] == "chance"
          # Luck alone: a fair flip on the turn's seeded dice, recorded and
          # rendered like a roll.
          won = ::Harness::RNG.current.rand(2).zero?
          res = { "outcome" => won ? "success" : "failure", "stat" => "chance", "action" => contest[:args]["action"] }
          tcs << tool_call("contest_chance", contest[:args].slice("actor_id", "target_id", "action"), res)
          ok  = true
        else
          res, ok = execute_tool(resolver, "resolve", contest[:args], into: tcs)
        end
        unless ok && res.is_a?(::Hash) && res["outcome"]
          @logger.warn { "[Runner conversation] contest roll failed (#{res.inspect[0, 140]}) — voicing plainly" }
          return contest
        end

        player_won = %w[success critical_success].include?(res["outcome"])
        grade = (res["margin"].to_s == "decisive" || res["critical"]) ? ", decisively" : ""
        payload = {
          "kind"    => (ability ? ability["name"] : (contest[:faculty] == "chance" ? "a game of chance" : (stat ? "#{stat} contest" : "persuasion"))),
          # Seat-relative verdict, rendered in Ruby. Handed the player-centric
          # outcome ("critical_failure"), the voicing model flipped ownership
          # (Leofstan conceding a game he'd won — deixis inversion). Who won
          # is computed here, never inferred by the model. Third person by
          # name: second-person payload strings get echoed back as "I"
          # (register pollution — the Bogumil first-person class).
          # First name: the target reads this in its own payload and the
          # voicing copies whatever name it is shown (2/2 full-name openers
          # under a full-name verdict, probe 8; 0/3 the turn before).
          "verdict" => (player_won ? "#{first_name(target)} lost — it went the player's way#{grade}" : "#{first_name(target)} won — the player's attempt failed#{grade}")
        }
        payload["effect"]     = ability["description"] if ability && player_won
        payload["player_won"] = player_won
        if (h = contest[:haggle])
          # The dice settle the PRICE. A won haggle brings the ware down to the
          # offer, floored at half the asking (a seller yields, never gives it
          # away); a lost one leaves it. Nothing changes hands here — the sale
          # is the player's next move, through buy_item at the settled price.
          floor = [ (h[:asking] / 2.0).ceil, 1 ].max
          price = player_won ? h[:offer].clamp(floor, h[:asking]) : h[:asking]
          if player_won
            props = h[:item].properties.dup
            props["haggled_price"] = price
            h[:item].update!(properties: props)
            tcs << tool_call("haggled", { "item_id" => h[:item].id, "target_id" => target["id"] },
                             { "item_name" => h[:item].name, "price" => price, "asking" => h[:asking] })
          end
          payload["kind"]    = "haggle"
          payload["ware"]    = h[:item].name
          payload["price"]   = price
          payload["verdict"] = player_won ? "#{first_name(target)} yielded on the price — the #{h[:item].name} now goes for #{price} coins" :
                                            "#{first_name(target)} held the price — the #{h[:item].name} stays at #{price} coins"
        end
        if (w = contest[:wager])
          moved = settle_wager!(w, player_won, player, target, resolver, tcs)
          payload["kind"]    = "wager"
          payload["wager"]   = true
          # The coins the verdict moved, as a number: the ledger refuses a
          # debt that restates them (see struck_deals).
          paid = player_won ? w[:against] : w[:stake]
          payload["paid_coins"] = paid[:coins] if paid.is_a?(::Hash) && paid[:coins].is_a?(::Integer)
          payload["action"]  = contest[:args]["action"]   # the standing bracket names the bet, not a press
          payload["verdict"] = if player_won
                                 "#{first_name(target)} lost the wager#{moved ? " — #{moved} went to the player" : ''}"
                               else
                                 "#{first_name(target)} won the wager#{moved ? " — #{moved} went to #{first_name(target)}" : ''}"
                               end
        end
        active&.record_contest!(key, payload)
        @logger.info { "[Runner conversation] contest #{key} → #{res['outcome']}#{res['xp_gained'] ? " (+#{res['xp_gained']}xp)" : ""}" }
        contest[:payload] = payload
        contest
      end

      # find_present / player_ability live in Runners::Base (shared with the
      # cast runner).

      def first_name(char)
        char["name"].to_s.split.first.to_s
      end

      # A gate candidate carrying a synthetic id (so knowledge-row ids and
      # event-row ids can't collide inside one gate call) + its source, so the
      # approved set splits back into facts vs memories.
      RecallItem = Struct.new(:id, :content, :src, :row)

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
        # Genesis mirrors each founding event into a knowledge row with the
        # same sentence; a participant's pool held both and the gate handed
        # the voice the fact twice (23 twins in 33 pools, run 8). The event,
        # dated and cast, stands for both.
        told = pool.grep(::Event).map { |e| e.details.is_a?(::Hash) ? e.details["summary"].to_s.strip : "" }.reject(&:empty?)
        pool = pool.reject { |r| r.is_a?(::Knowledge) && told.include?(r.content.to_s.strip) } if told.any?
        return { "knowledge" => [], "events" => [], "fed" => { "facts" => [], "events" => [] } } if pool.empty?

        ranked = ranker.call(pool, topic: topic).first(RECALL_CAP)
        cands = ranked.map.with_index(1) do |row, i|
          if row.is_a?(::Knowledge)
            RecallItem.new(i, row.content, :knowledge, row)
          else
            RecallItem.new(i, dated_memory_text(row, context.game_time, exclude_id: char.id), :event, row)
          end
        end

        approved = ::Harness::Knowledge::Gate.run(llm: llm(context), topic: topic, facts: cands, logger: @logger)
        out = { "knowledge" => approved.select { |c| c.src == :knowledge }.map(&:content),
                "events"    => approved.select { |c| c.src == :event }.map(&:content),
                # [row id, text] pairs of what was handed over — the reflection's
                # world judge names records by them (additions).
                "fed"       => { "facts"  => approved.select { |c| c.src == :knowledge }.map { |c| [ c.row.id, c.content ] },
                                 "events" => approved.select { |c| c.src == :event }.map { |c| [ c.row.id, c.content ] } } }
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
      def dated_memory_text(event, now, exclude_id: nil)
        parts  = event.event_participants.to_a
        marks  = [ ago_phrase(now.to_i - event.game_time.to_i),
                   (HEARSAY_MARK if parts.any? { |p| p.character_id == exclude_id && p.role == "hearer" }) ].compact
        base   = marks.any? ? "(#{marks.join(', ')}) #{event.recall_text}" : event.recall_text
        # Hearers were told, not there — they never enter the "(with …)" cast.
        cast   = cast_suffix(parts.reject { |p| p.role == "hearer" }.map(&:character_id), exclude_id)
        cast ? "#{base} #{cast}" : base
      end

      # A holder who only HEARD of a happening (participant role "hearer" —
      # the transmission edge Capture writes at a telling) recalls it as
      # hearsay, marked so the voicing knows it is second-hand.
      HEARSAY_MARK = "heard tell"

      def ago_phrase(delta_minutes)
        days = delta_minutes / ::Harness::Clock::MINUTES_PER_DAY
        return nil if days < 1
        return "yesterday" if days == 1
        return "#{days} days past" if days < 30
        n = days < 360 ? days / 30 : days / 360
        unit = days < 360 ? "moon" : "winter"
        "#{n} #{unit}#{'s' if n > 1} past"
      end

      # Voice ONE character. The call sees this character's own events, the
      # public roster of who else is here, and the shared thread — never
      # anyone else's events.
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

      # A LOST contest settles the are-you-speaking deliberation the way the
      # unprompted frame does — the dice ruled, the prose renders. Without it
      # the verdict sat in the payload as advice while the decline duty
      # ("silence is correct and common") stayed a duty: Irenka "still
      # smarting from the player's successful persuasion" answered a direct
      # question with silence. Rides after the payload, prefix-safe.
      VERDICT_FRAME = <<~FRAME
        --- VERDICT ---
        The dice ruled this press against you: <<KIND>>. The are-you-speaking deliberation is settled — output the same JSON with "speak": true and yield in your manner: say or give what was pressed for.
      FRAME

      # A won haggle: the outcome is a price, not a yield. Told to "say or
      # give what was pressed for", the seller gave the player the coins.
      HAGGLE_FRAME = <<~FRAME
        --- VERDICT ---
        The dice settled the price: the <<WARE>> goes for <<PRICE>> coins. The are-you-speaking deliberation is settled — output the same JSON with "speak": true and name the price in your manner; the sale itself is the player's next move.
      FRAME

      # The other verdict. A press the player LOST had no teeth: the target
      # read "Edmund won — the player's attempt failed" in its payload and
      # answered the question anyway (probe 6, a critical failure, straight
      # answer). The dice are causal both ways, so the winner is told to hold.
      # The scene ledger keeps the verdict; a second press meets it as a
      # payload fact, not this frame again. Rides after the payload, prefix-safe.
      HELD_FRAME = <<~FRAME
        --- VERDICT ---
        The dice ruled this press in your favour: <<KIND>>. You are not moved. The are-you-speaking deliberation is settled — output the same JSON with "speak": true and hold in your manner: what was pressed for stays withheld — refuse it, deflect, or turn it back on them.
      FRAME

      # A wager: the stakes moved by the engine on the verdict, both ways.
      WAGER_FRAME = <<~FRAME
        --- VERDICT ---
        The dice settled the wager: <<VERDICT>>. The stakes have already changed hands. The are-you-speaking deliberation is settled — output the same JSON with "speak": true and take the result in your manner.
      FRAME

      def verdict_frame(contest, v)
        return nil unless contest && v[:kind] == :npc && v[:char]["id"] == contest[:target_id]
        payload = contest[:payload]
        return nil unless payload.is_a?(::Hash) && payload.key?("player_won")
        return nil if payload["repeat"] && !payload["player_won"]   # a re-served HOLD rides as a payload fact only
        return WAGER_FRAME.sub("<<VERDICT>>") { payload["verdict"].to_s } if payload["wager"] && !payload["repeat"]
        if payload["ware"] && payload["player_won"]
          return HAGGLE_FRAME.sub("<<WARE>>") { payload["ware"].to_s }.sub("<<PRICE>>") { payload["price"].to_s }
        end
        (payload["player_won"] ? VERDICT_FRAME : HELD_FRAME).sub("<<KIND>>") { payload["kind"].to_s }
      end

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

        emit, voicing_user, fed = voice_one(context, input, step, player, v, roster,
                                       thread_with_current(conversation_thread(context), input, transcript&.tool_calls),
                                       nearby_places(context), wares_here(context),
                                       resolver, tcs, active, nil, frame: frame)
        prose = emit&.dig("dialogue", "prose").to_s.strip
        if emit.nil? || !emit["speak"] || prose.empty?
          @logger.info { "[Runner conversation] unprompted voicing declined for #{npc.name} (speak=#{emit && emit['speak'].inspect})" }
          transcript&.record_tool_calls(tcs)
          return nil
        end
        return nil unless apply_emit(resolver, context, scene, emit, v, player, tcs, input: input)

        active&.mark_spoken!(npc.id)
        reflect_knowledge(context, v, emit, fed, unprompted: true, tool_calls: tcs)
        reevaluate_state(context, v, emit, active, fed, tcs)
        transcript&.record_tool_calls(tcs)
        prose
      end

      private

      def voice_one(context, input, step, player, v, roster, thread, nearby, wares, resolver, tcs, active, contest = nil, frame: nil, recall_gate: true)
        you, fed_events = npc_knowledge(resolver, v[:char], tcs, active, event_cap: EVENT_SUMMARY_CAP, now: context.game_time)
        # The judged addressee is TOLD the words are theirs — the judge's
        # ruling is a fact of the turn, and left to work it out again the
        # voice read "that mace" as the trader's and held its tongue (run 7
        # t9). The last speaker on an unbound turn rides the same flag.
        you["addressed"] = true if v[:addressed] || v[:continuing]
        fed = { "events" => fed_events, "facts" => [] }
        # The contest verdict rides in the TARGET's you-block — the dice have
        # ruled; the voicing renders the consequence, it does not re-judge.
        if contest && contest[:payload] && v[:kind] == :npc && v[:char]["id"] == contest[:target_id]
          you = you.merge("contest" => contest[:payload])
        end
        # Recall (likely speakers only — see run's recall_gate): knowledge
        # facts AND own memories through one relevance gate. The gated-relevant
        # memories (plus a small recency floor for continuity) REPLACE the raw
        # event dump; relevant facts land in `knowledge`. Empty candidate pool
        # → no gate call. Skipped pollees keep the raw event dump untouched.
        if v[:kind] == :npc && recall_gate && (npc_row = ::Npc.find_by(id: v[:char]["id"]))
          # Topic = input + planner intent. A thin input ("who?", "go on")
          # embeds as nearly nothing; the intent already describes what's
          # being sought — free query expansion, no extra LLM call.
          topic = input.to_s.strip
          r = recall(context, npc_row, topic)
          floor = Array(you["events"]).first(RECALL_EVENT_FLOOR)
          you = you.merge("events" => (floor + r["events"]).uniq)
          you = you.merge("knowledge" => r["knowledge"]) if r["knowledge"].any?
          given = r["fed"] || {}
          fed = { "events" => (fed_events.first(RECALL_EVENT_FLOOR) + Array(given["events"])).uniq(&:first),
                  "facts"  => Array(given["facts"]) }
        end
        others = roster.reject { |r| r["name"] == v[:char]["name"] }
        # Key ORDER matters for KV-cache reuse across the turn's per-NPC calls:
        # the invariant block (same player/input/intent/nearby/thread for every
        # speaker this turn) leads, so llama.cpp reuses that prefix; the per-NPC
        # varying blocks (others_present, you) come LAST. JSON is order-agnostic
        # to the model, so this is a pure prefill win, no behaviour change.
        invariant = {
          "player"          => { "id" => player.id, "name" => player.name,
                                 "gender" => (player.properties.is_a?(::Hash) ? player.properties["gender"] : nil) }.compact,
          "player_input"    => input,
          "location"        => location_payload(context),
          "nearby_places"   => nearby
        }
        # Venue stock (invariant across speakers, absent outside shops): the
        # smith could not see her own racks and denied weapons standing next
        # to eight for-sale wares — the context-exposure class again.
        invariant["wares_here"] = wares unless wares.nil?
        # What the engine already did this turn, as the player saw it: the
        # buy that went through, the coins refused ("You can't afford it").
        # Never shown it, the voice took coins the player did not have and
        # the ledger struck a sale on credit nobody meant (run 7 t5).
        just_now = engine_this_turn(context, tcs)
        invariant["just_now"] = just_now unless just_now.empty?
        user = JSON.pretty_generate(invariant.merge(
          "exchange_so_far" => thread,
          "others_present"  => others,
          "you"             => you
        ))
        sent_user = "INPUT:\n#{user}"
        # The unprompted frame (initiative voicing) rides AFTER the payload so
        # the shared prefix stays cache-identical with normal voicings.
        sent_user = "#{sent_user}\n\n#{frame}" if frame
        who = v[:char]["name"]
        emit = ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          raw = llm(context).complete(system: preamble, user: sent_user, schema: VOICING_SCHEMA, max_tokens: VOICING_MAX_TOKENS)
          e1  = parse_emit(raw)
          # One correction bounce: a malformed emit (bad JSON, or a speaker with
          # no line — the "pro"-for-"prose" class) goes back to the model with
          # the defect named. Same prefix, so the retry is KV-cache-hot.
          if (defect = emit_defect(e1))
            @logger.warn { "[Runner conversation] #{who} emit malformed (#{defect}) — retrying once" }
            raw = llm(context).complete(system: preamble, user: "#{sent_user}\n\n#{retry_tail(defect, raw)}", schema: VOICING_SCHEMA, max_tokens: VOICING_MAX_TOKENS)
            e1  = parse_emit(raw)
            if (still = emit_defect(e1))
              @logger.warn { "[Runner conversation] #{who} emit still malformed (#{still}) — dropped" }
            end
          end
          e1
        end
        # The exact user string rides along for the taking-stock pass (same
        # prefix); `fed` is what THIS speaker was handed — records with ids,
        # the thread, the room — for the reflection judges' clean contexts.
        fed = fed.merge("thread" => thread, "input" => input, "others" => others.map { |o| o["name"] },
                        "places" => Array(nearby).map { |n| n["name"] })
        emit ? [ emit, sent_user, fed ] : nil
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
        if emit["speak"] && prose.empty?
          # Explicit prose: "" is the grammar's escape hatch — a break-off,
          # handled (and logged) by apply_emit. Absent/null dialogue is
          # format loss of a line that likely existed — worth one bounce.
          return nil if dlg.is_a?(::Hash) && dlg["prose"].is_a?(::String)
          return "\"speak\" is true but dialogue.prose is missing"
        end
        nil
      end

      def retry_tail(defect, raw)
        "--- RETRY ---\nYour previous output was rejected: #{defect}.\n" \
        "Previous output:\n#{echo_for_retry(raw)}\n\nRe-emit the ENTIRE corrected JSON object now."
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
      # narration only; the hands and the reflection judges persist on their
      # own consequential paths.
      def apply_emit(resolver, context, scene, emit, v, player, tcs, input: nil, contest: nil)
        dlg     = emit["dialogue"]
        prose   = dlg.is_a?(Hash) ? dlg["prose"].to_s.strip : ""
        engaged = emit["speak"] || prose != ""
        @logger.debug do
          "[Runner conversation] #{v[:char]['name']} emit: speak=#{!!emit['speak']} dialogue=#{prose != ''} " \
          "thought=#{emit['thought'].to_s[0, 120].inspect}"
        end
        return false unless engaged
        if emit["speak"] && dlg.is_a?(Hash) && prose == ""
          @logger.info { "[Runner conversation] #{v[:char]['name']} spoke-empty (in-grammar break-off) — treated as silence" }
          return false
        end

        actor_id = v[:char]["id"]

        # PARROT GAUGE (log only): a line that reproduces one already staged
        # this scene is logged, never suppressed. The suppressor this used to
        # be traded a repeat for a void — "No one reacts." to a re-ask — and
        # the shapes it caught were fixed where they originate: the same-turn
        # hearsay amplifier (tails deferred), the restate-then-add chorus
        # (bystander frame), the seed-copied gesture (separate doing seed).
        # A recurrence shows up here and in the probe tally; fix its source
        # (ruling 2026-09-12: remove the pathology, not the symptom).
        active = context.active_scene
        if prose != "" && (echoed = parroted_line_owner(active, prose))
          who   = ::Character.find_by(id: actor_id)&.name || actor_id
          whose = echoed == actor_id ? "their own earlier line" : "#{::Character.find_by(id: echoed)&.name || echoed}'s line"
          @logger.info { "[Runner conversation] parrot-shaped emit — #{who} repeats #{whose} (kept)" }
        end

        spoke = false
        if prose != ""
          stage_line(actor_id, player, dlg, tcs)
          active&.record_line!(actor_id, prose)
          spoke = true
        end
        # THE HANDS: what the line did, judged by its own call and performed
        # (act_on_line); the reflection judges read `did` as what happened.
        emit["did"], emit["not_done"] = spoke ? act_on_line(resolver, context, actor_id, prose, input, player, contest, tcs) : [ [], nil ]
        spoke
      end

      # The id of the character whose last staged line this prose reproduces,
      # nil when it reproduces none. Exact after normalization, or a shared
      # verbatim run: SPEECH_RUN chars of quoted speech when both lines carry
      # quotes (the beat is ignored then — a compliant model reuses its
      # gesture verbatim around new words), else PARROT_RUN chars of whole
      # line. Scene-wide, the speaker's own line included; the caller says
      # whose it was.
      PARROT_RUN = 60
      SPEECH_RUN = 30
      def parroted_line_owner(active, prose)
        priors = active&.last_lines || {}
        return nil if priors.empty?
        a  = normalize_line(prose)
        sa = normalize_speech(prose)
        hit = priors.find do |_id, last|
          sb = sa && normalize_speech(last)
          if sb
            sa == sb || shared_run?(sa, sb, SPEECH_RUN)
          else
            b = normalize_line(last)
            a == b || shared_run?(a, b, PARROT_RUN)
          end
        end
        hit&.first
      end

      def normalize_line(s)
        s.to_s.downcase.gsub(/\s+/, " ").strip
      end

      # Quoted spans: double quotes of any typography, and single quotes once
      # intra-word apostrophes (Kiln's, you're) are dropped — those are not
      # delimiters. nil when the line carries no quoted speech.
      def normalize_speech(s)
        text  = s.to_s.gsub(/(?<=\p{L})[’'](?=\p{L})/, "")
        spans = text.scan(/["“”„]([^"“”„]+)["“”„]|[‘']([^‘’']+)[’']/).flatten.compact
        return nil if spans.empty?
        spans.join(" ").downcase.gsub(/[^\p{L}\p{N}\s]/, " ").gsub(/\s+/, " ").strip
      end

      # Any `run`-char window of `a` appearing verbatim in `b`. Brute windows
      # over two ≤~1-2K-char strings — trivial per turn.
      def shared_run?(a, b, run)
        return false if a.length < run || b.length < run
        (0..(a.length - run)).any? { |i| b.include?(a[i, run]) }
      end

      # Prefetch what THIS character could plausibly know (Ruby/SQL, no LLM) AND
      # who they are to voice — personality (stored at materialization), current
      # mood and scene agenda (seeded at scene entry). query_events already
      # scopes to this holder (own + witnessed + local), so the events list is
      # strictly this character's knowledge; no other character's memories enter.
      def npc_knowledge(resolver, char, tcs, active, event_cap: EVENT_SUMMARY_CAP, now: nil)
        res, _ = execute_tool(resolver, "query_events", { "for_holder_id" => char["id"], "limit" => event_cap }, into: tcs)
        # [event id, text] pairs: the text is what the voicing sees; the id is
        # what the reflection's world judge can name (an addition to it).
        fed_events = Array(res.is_a?(Hash) ? res["events"] : res)
          .map { |e| [ (e.is_a?(::Hash) ? e["id"] : nil), event_text(e, exclude_id: char["id"]) ] }
          .reject { |_, t| t.empty? }
        events = fed_events.map(&:last)
        row   = ::Npc.find_by(id: char["id"])
        props = row&.properties
        # Mood and agenda ride EVERY turn — the post-emit reevaluation
        # keeps them current, so they can't yank a spoken NPC back to a stale
        # seed. Mood leads with the disposition-ladder word: the standing
        # temperature toward the player.
        # The model calls itself whatever `name` says: given the full name it
        # opened nine lines in ten with "Roderic Marston shifts…" whatever
        # the prompt asked (2026-09-12). First name here; the surname rides
        # separately for when someone asks.
        you = {
          "id"          => char["id"],
          "name"        => char["name"].to_s.split.first,
          "full_name"   => (char["name"] if char["name"].to_s.split.size > 1),
          "subrole"     => char["subrole"],
          "lens"        => char["lens"],
          "personality" => (props["personality"] if props.is_a?(::Hash)),
          "appearance"  => ((props["appearance"] || props["physical"]) if props.is_a?(::Hash)),
          "mood"        => mood_line(active, char["id"]),
          # The current activity microbeat — a decliner's reference for
          # "simply carry on" (without it Bram returned to his ledger thrice,
          # each rewrite re-rendering him). Handed over until the first line,
          # then only when refreshed since the last one: a standing doing was
          # performed as the opening gesture of every line.
          "doing"       => active&.doing_for_voicing(char["id"]),
          "agenda"      => active&.agenda_for(char["id"]),
          "debts"       => debts_for(char["id"], now),
          # The purse, and what this trade can bring out on its own word
          # (Items::Offers) — facts about their means; the act judge binds
          # what the line then does with them. An empty list is the fact,
          # not an absent key: with the key absent a labourer drew a belt
          # knife he did not have and the judge had to refuse it (hands run 1).
          "coins"       => row&.coins.to_i,
          # What they have on them, by name: the inventory the hatchery rolls
          # for every NPC and nobody was told about — a hand went to a dagger
          # the row never had, and the heavy dirk it did have was never drawn
          # (hands run 6).
          "carry"       => (row.is_a?(::Npc) ? row.items.map(&:name).sort.presence : nil),
          "can_offer"   => (row.is_a?(::Npc) ? ::Harness::Items::Offers.categories_for(row, active&.location) : nil),
          "events"      => events
        }.compact
        [ you, fed_events ]
      end

      # Outstanding obligations from this character's seat — the durable half
      # of "keeping track of what you are owed", broken ones included (a
      # missed meeting is a grudge, not a closed book). Settled truth like a
      # contest verdict: the voicing acts on it (collect, honor, press),
      # never re-litigates whether the deal exists.
      DEBT_CAP = 4
      def debts_for(id, now = nil)
        name = ::Character.find_by(id: id)&.name
        ::Obligation.outstanding.involving(id).order(id: :desc).limit(DEBT_CAP)
                    .map { |o| o.line_for(id, now: now, name: name) }.reverse.presence
      rescue ::StandardError
        nil
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
      def event_text(e, exclude_id: nil)
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
        text = text.to_s.strip[0, EVENT_TEXT_CAP].to_s
        # Text-less rows (resolve's mechanical logs) must stay empty so the
        # caller's reject(&:empty?) drops them — a bare " (with Kaol)" cast
        # suffix on a blank line resurrects what the filter exists to kill.
        return text if text.empty?
        parts = Array(e["participants"])
        if !text.empty? && parts.any? { |p| p.is_a?(::Hash) && p["character_id"] == exclude_id && p["role"] == "hearer" }
          text = "(#{HEARSAY_MARK}) #{text}"
        end
        cast = cast_suffix(parts.reject { |p| p.is_a?(::Hash) && p["role"] == "hearer" }.map { |p| p.is_a?(::Hash) ? p["character_id"] : nil }, exclude_id)
        cast ? "#{text} #{cast}" : text
      end

      # The participation graph, surfaced: an event names its cast so a shared
      # moment reads as a LINK between the people in it. The rows store who
      # was involved; without this the names were thrown away at the exact
      # moment the model needed them (Torvin "remembering" a referral that
      # named no referrer). The holder is left out — it's their own memory.
      CAST_CAP = 4
      def cast_suffix(ids, exclude_id)
        ids = ids.compact.uniq - [ exclude_id ]
        return nil if ids.empty?
        names = ::Character.where(id: ids.first(CAST_CAP)).pluck(:name)
        names.empty? ? nil : "(with #{names.join(', ')})"
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
        nearby_rows(context).map do |l|
          entry = { "name" => l.name }
          d = l.description.to_s.strip
          # Sanity ceiling — 80 cut one-liner descriptions mid-word
          # ("smelling of wet ea"); a whole description is selection's job
          # (it's already a one-liner), not truncation's.
          entry["about"] = d[0, 240] unless d.empty?
          entry
        end
      end

      def nearby_rows(context)
        loc = context.player_location
        return [] unless loc
        rows = []
        rows << loc.parent if loc.parent
        if loc.parent_id
          rows.concat(::Location.where(parent_id: loc.parent_id).where.not(id: loc.id).limit(PLACES_CAP).to_a)
        end
        rows.concat(::Location.where(parent_id: loc.id).limit(PLACES_CAP).to_a)
        rows.uniq(&:id).first(PLACES_CAP)
      end

      # For-sale stock anchored at the scene, with the settlement's mechanical
      # buy prices. An EMPTY list where nothing is for sale: the key used to be
      # absent there, and absence read as "no rule applies" — a sawyer with no
      # table quoted squared pine at ten coins and the player paid for air
      # (items run 5, t2–t4). [] is a fact the voice can read.
      def wares_here(context)
        loc = context.player_location
        return nil unless loc
        items = ::Item.where(location_id: loc.id).select { |i| i.properties.is_a?(::Hash) && i.properties["for_sale"] }
        return [] if items.empty?
        # Whose table each thing is on — a market has several (items run 8
        # t13: a flat list, and the fishmonger quoted the clothier's bolt as his).
        sellers = ::Character.where(id: items.map { |i| i.properties["seller_id"] }.compact.uniq).pluck(:id, :name).to_h
        items.map do |i|
          h = { "name" => i.name, "price" => ::Harness::Tools::QueryScene.shop_price(i, loc) }
          h["seller"] = sellers[i.properties["seller_id"]] if sellers[i.properties["seller_id"]]
          h
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

      # Same-turn visibility: `narrations` holds only COMPLETED turns, so a
      # second speaker — or the initiative beat after the runner finished —
      # would answer blind to what a co-speaker just said (two answers to the
      # same question, or a beat re-deriving the moment). Lines already staged
      # THIS turn ride in as the current exchange entry, so a later voice
      # answers the room as it now stands and the decide-gate can choose
      # silence over restating an answer someone already gave.
      def thread_with_current(thread, input, tool_calls)
        said = Array(tool_calls).filter_map do |tc|
          tc.dig("args", "details") if tc["name"] == "propose_event" && tc.dig("result", "staged")
        end
        return thread if said.empty?
        thread + [ { "player" => input.to_s, "scene" => said.join("\n\n") } ]
      end

      # Stage a line for NARRATION without PERSISTING it. Committing every "she
      # slams her mug" as a durable event is what fills a thin character's soul
      # with atmosphere and feeds it back as knowledge next turn. Intra-scene
      # memory comes from exchange_so_far; durable memory comes only from the
      # hands and the reflection judges (consequential by nature).
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
      def who_for(v)
        v[:char]["name"]
      end

      # THE HANDS — the act judge. What a speaker did with their hands is read
      # off the line they spoke, by its own call: one act, bound as ids from
      # its payload, at zero temperature, a directed `reasoning` clause before
      # the act in place of thinking mode. The voicing used
      # to carry this as a `beat` array beside eight other fields, bounced
      # with the whole emit; it fired on about half the hand-overs it
      # narrated, once with no item on it (items run 9 t9), and minted every
      # give from a label even when the thing was already on the table. The
      # engine's gates (trade, table, phase budget, purse, debt) stay as
      # refusals, named back once in a correction bounce; an act still
      # refused after that is dropped and the line stands as a lapse — prose
      # never moves a coin. Returns the `did` lines for the reflection judges.
      # "table", not "offer": the English verb is in every other hand-over
      # line ("offers it to Maelyn") and the judge mapped it to the enum —
      # a bowl of stew handed to the player became a row for sale (hands
      # run 3, t1). The act is what the engine does: a thing put on the
      # table for sale.
      # `receive` is the run-9 slot: on "counts out the coins and places them in
      # her palm" the judge reasoned "Edith receives coins" and, with nowhere to
      # file that, answered give — coins to the player; "fingers close around
      # the hilt" minted a second knife the same way (hands run 9 t5, t18).
      ACT_KINDS = %w[none receive give table leave attack].freeze

      # AT HAND — the judge behind the trade gate. Provisions and goods a
      # person of this trade and station would have about them (a labourer
      # her bucket, a farmer a horseshoe) can be brought out on their word
      # even when the trade map lists nothing; weapons, armour, jewels and
      # magical things never can — those come from the roll or the trade.
      MINT_PROMPT_PATH  = Rails.root.join("lib/harness/prompts/mint.txt")
      MINT_SCHEMA = {
        "type" => "object",
        "properties" => { "reasoning" => { "type" => "string" }, "has" => { "type" => "boolean" } },
        "required" => %w[reasoning has], "additionalProperties" => false
      }.freeze
      SIGNIFICANT_KINDS = %w[weapons armor jewelry magical].freeze

      # Returns [what was done, what the engine refused]: the refusal is a
      # fact the speaker's later judges read ("Nothing changed hands: …"),
      # so a knife the voice invented is not "gone from his belt" downstream.
      def act_on_line(resolver, context, actor_id, prose, input, player, contest, tcs)
        npc = ::Npc.find_by(id: actor_id)
        return [ [], nil ] unless npc
        act, refused = judge_act(context, npc, prose, input, player, contest, tcs)
        return [ [], refused ] unless act && !%w[none receive].include?(act["act"])
        did = perform_act!(resolver, context, act, npc, player, tcs)
        @logger.info { "[Runner conversation] #{npc.name} act #{act['act']} → #{did.any? ? did.join('; ') : 'nothing moved'}" }
        [ did, nil ]
      end

      def judge_act(context, npc, prose, input, player, contest, tcs)
        system = (@act_prompt ||= File.read(ACT_PROMPT_PATH))
        user   = "INPUT:\n#{JSON.pretty_generate(act_payload(context, npc, prose, input, player, contest, tcs))}"
        ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          raw = llm(context).complete(system: system, user: user, schema: ACT_SCHEMA, max_tokens: JUDGE_MAX_TOKENS, temperature: 0, thinking: false)
          act = parse_emit(raw)
          kind, defect = act_defect(act, npc, context, player, tcs)
          if kind == :bounce
            # A defect of form — an id not in the payload, a shape the
            # grammar allowed but the act needs — goes back once, named.
            @logger.info { "[Runner conversation] #{npc.name} act rejected (#{defect}) — retrying once" }
            raw = llm(context).complete(system: system, user: "#{user}\n\n#{retry_tail(defect, raw)}", schema: ACT_SCHEMA, max_tokens: JUDGE_MAX_TOKENS, temperature: 0, thinking: false)
            act = parse_emit(raw)
            kind, defect = act_defect(act, npc, context, player, tcs)
          end
          if kind
            # A refusal is final: told "category must be one of provisions",
            # the judge called a hoe a provision and the engine minted it as
            # food (hands run 1, t17). The line stands as a lapse.
            @logger.info { "[Runner conversation] #{npc.name} act #{kind == :refuse ? 'refused' : 'still rejected'} (#{defect}) — the line stands, nothing moves" }
            return [ nil, defect ]
          end
          [ act, nil ]
        end
      rescue StandardError => e
        @logger.warn { "[Runner conversation] act judge failed for #{npc.name}: #{e.class}: #{e.message}" }
        [ nil, nil ]
      end

      # What the judge sees: the character's means (purse, trade, table,
      # debts), who is here and where they could go, both lines, what the
      # engine has already done this turn, and — for a contest's target —
      # the settled verdict. The receipts matter: a seller narrating her
      # hands on the jar the player had just bought in the same turn was
      # read as bringing out a second jar (hands run 1, t9).
      def act_payload(context, npc, prose, input, player, contest, tcs)
        loc   = context.player_location
        props = npc.properties.is_a?(::Hash) ? npc.properties : {}
        you = {
          "id"        => npc.id,
          "name"      => npc.name,
          # How they look: a judge shown only the name took the fisher for
          # the player and gave him the cheese he had just been handed
          # (hands run 5, t16).
          "looks"     => (props["appearance"] || props["physical"]).presence,
          "coins"     => npc.coins.to_i,
          "can_offer" => ::Harness::Items::Offers.categories_for(npc, loc),
          "on_table"  => own_wares(npc, context).map { |i| { "id" => i.id, "name" => i.name, "price" => ::Harness::Tools::QueryScene.shop_price(i, loc) } }.presence,
          "carried"   => npc.items.order(:id).map { |i| { "id" => i.id, "name" => i.name } }.presence,
          "debts"     => debts_for(npc.id, context.game_time)
        }.compact
        # Things lying loose here, by id: a smith lifting the bow off her
        # bench hands over THAT bow. Without them the judge could only mint
        # from the label, and a second bow appeared beside the first (hands
        # run 4, t21). Other sellers' wares are not hers to hand over.
        you["here"] = loose_here(context).map { |i| { "id" => i.id, "name" => i.name } }.presence
        you.compact!
        present = [ { "id" => player.id, "name" => player.name, "player" => true } ]
        present += ::Npc.where(location_id: loc.id).where.not(id: npc.id).map { |n| { "id" => n.id, "name" => n.name } } if loc
        payload = {
          "you"           => you,
          "present"       => present,
          "nearby_places" => nearby_rows(context).map { |l| { "id" => l.id, "name" => l.name } },
          "player_said"   => input,
          "this_turn"     => engine_this_turn(context, tcs),
          "you_said"      => prose
        }
        payload["contest"] = contest[:payload] if contest && contest[:payload] && contest[:target_id] == npc.id
        payload
      end

      # The engine's receipts so far this turn — earlier steps' tool calls
      # (the turn transcript) and this runner's own — in the lines the player
      # was shown. Parts is the one renderer of what changed hands.
      def perform_act!(resolver, context, a, npc, player, tcs)
        did = []
        case a["act"]
        when "give"
          target = present_by_id(a["to_id"], context, player)
          if a["item_id"]
            # A thing already here changes hands as it is: off sale if it was
            # for sale, into the giver's hands, then across like any carried thing.
            item  = (own_wares(npc, context) + loose_here(context) + npc.items.to_a).find { |i| i.id == a["item_id"] }
            props = item.properties.is_a?(::Hash) ? item.properties.dup : {}
            %w[for_sale seller_id haggled_price].each { |k| props.delete(k) }
            item.update!(character_id: npc.id, location_id: nil, properties: props)
            _, ok = execute_tool(resolver, "give_item", { "item_id" => item.id, "from_id" => npc.id, "to_id" => target.id }, into: tcs)
            did << "handed #{target.name} #{item.name}" if ok
          elsif things(a).any?
            # Things brought out exist from this moment: minted in the
            # giver's hands, then moved like any other item.
            things(a).each do |t|
              item = ::Harness::Items::Offers.materialize!(npc, category: t["category"], label: t["item"], game_time: context.game_time, to: npc)
              next unless item
              _, ok = execute_tool(resolver, "give_item", { "item_id" => item.id, "from_id" => npc.id, "to_id" => target.id }, into: tcs)
              did << "handed #{target.name} #{item.name}" if ok
            end
          else
            res, ok = execute_tool(resolver, "transfer_coins", {
              "from_id" => npc.id, "to_id" => target.id, "amount" => a["coins"].to_i,
              "reason"  => "handed over in conversation"
            }, into: tcs)
            if ok
              settled = res.is_a?(Hash) && res.dig("obligation", "status") == "settled"
              did << "paid #{target.name} #{a['coins'].to_i} coins#{settled ? ', settling the debt' : ''}"
            end
          end
        when "table"
          # On the table: a for-sale row here with the seller recorded, at the
          # engine's price. The player's next line binds to it (buy, take,
          # walk away); wares_here quotes it back to every voice.
          loc = context.player_location
          things(a).each do |t|
            item = ::Harness::Items::Offers.materialize!(npc, category: t["category"], label: t["item"], game_time: context.game_time, at: loc)
            next unless item
            price = ::Harness::Tools::QueryScene.shop_price(item, loc)
            tcs << tool_call("offer_item", { "seller_id" => npc.id, "item_id" => item.id },
                             { "item_id" => item.id, "item_name" => item.name, "seller_id" => npc.id, "price" => price })
            did << "put #{item.name} on the table at #{price} coins"
          end
        when "leave"
          dest = leave_destination(a["place_id"], npc, context)
          leave!(npc, dest, context, player, tcs)
          did << "left for #{dest.name}"
        when "attack"
          _, ok = execute_tool(resolver, "start_combat", {
            "sides" => [
              { "name" => "player_party", "members" => [ player.id ] },
              { "name" => "hostiles",     "members" => [ npc.id ] }
            ],
            "initiator_id"  => npc.id,
            "inciting_beat" => "#{npc.name} turns on #{player.name}"
          }, into: tcs)
          did << "attacked #{player.name}" if ok
        end
        did
      end

      def combat_started?(tcs)
        tcs.any? { |t| t["name"] == "start_combat" && !(t["result"].is_a?(Hash) && t["result"].key?("error")) }
      end

      # The engine's gates, by id, in the third person (the judge is not the
      # character). Nil when the act can be performed; else [kind, message]:
      # :bounce for a defect of form the judge can correct (an id not in the
      # payload, a missing binding), :refuse for an act the world will not
      # honour whatever the answer (nothing to bring out, a kind outside the
      # trade, the table or the day full, coins with no debt, steel from a
      # peaceable trade). A refusal never goes back for a second answer.
      def act_defect(a, npc, context, player, tcs = [])
        return [ :bounce, "not valid JSON" ] unless a.is_a?(::Hash)
        return [ :bounce, "act must be one of #{ACT_KINDS.join(', ')}" ] unless ACT_KINDS.include?(a["act"])
        offers = ::Harness::Items::Offers
        case a["act"]
        when "give"
          target = present_by_id(a["to_id"], context, player)
          return [ :bounce, "give: to_id #{a['to_id'].inspect} is not a present id" ] unless target
          return [ :bounce, "give: #{npc.name} cannot give to themselves" ] if target.id == npc.id
          if a["item_id"]
            return [ :bounce, "give: item_id #{a['item_id']} is not carried by #{npc.name}, on their table or lying here" ] unless (own_wares(npc, context) + loose_here(context) + npc.items.to_a).any? { |i| i.id == a["item_id"] }
            # Taking is not giving: the mace the player handed back went
            # straight back to the player (run 7 t11, both attempts).
            return [ :refuse, "give: item #{a['item_id']} came into #{npc.name}'s hands this turn — taking it is not giving it" ] if received_this_turn?(npc, context, tcs, item_id: a["item_id"])
          elsif things(a).any?
            things(a).each do |t|
              if (d = thing_defect(t, a["act"], npc, context))
                return [ d[0], "give: #{d[1]}" ]
              end
            end
          else
            amount = a["coins"]
            return [ :bounce, "give needs coins, an item_id from on_table, or an item brought out" ] unless amount.is_a?(::Integer) && amount > 0
            # Coins they do not have is a misread of the line, not a sum to
            # correct: bounced with the purse named, the judge gave the one
            # coin it had — to the player who had just paid (hands run 9 t5).
            return [ :refuse, "give: #{npc.name} has not got that many coins" ] if amount > npc.coins.to_i
            return [ :refuse, "give: #{amount} coins came into #{npc.name}'s hands this turn — taking them is not giving them" ] if received_this_turn?(npc, context, tcs, coins: amount)
            # Coins leave a character for a debt they owe or a press they
            # lost — handed two coppers for barley, a seller "paid the player
            # two coins" back (items run 6, t4 and t5, both first attempts).
            return [ :refuse, "give: #{npc.name} owes #{target.name} nothing and lost no press to them — coins do not flow that way" ] unless coins_due?(npc, target, context)
          end
        when "table"
          return [ :bounce, "table needs `things` — what #{npc.name} calls each thing set out" ] if things(a).empty?
          things(a).each do |t|
            if (d = thing_defect(t, a["act"], npc, context))
              return [ d[0], "table: #{d[1]}" ]
            end
          end
          if offers.on_table(npc, context.player_location) + things(a).size > offers::TABLE_CAP
            return [ :refuse, "table: #{npc.name} already has #{offers::TABLE_CAP} things on the table" ]
          end
        when "leave"
          return [ :bounce, "leave: place_id #{a['place_id'].inspect} is not among nearby_places" ] unless leave_destination(a["place_id"], npc, context)
        when "attack"
          return [ :refuse, "attack: #{npc.name} is not the kind who draws steel" ] unless ::Harness::Combat::FightCapable.fight_capable?(npc)
          target = present_by_id(a["to_id"], context, player)
          return [ :bounce, "attack: to_id #{a['to_id'].inspect} is not a present id" ] unless target
          return [ :bounce, "attack: only the player can be attacked here" ] unless target.is_a?(::Player)
          return [ :refuse, "attack: already in combat" ] if context.active_scene&.in_combat?
        end
        nil
      end

      # Did this thing, or this sum, come INTO the character's hands this turn
      # — the player's give, payment or purchase? The judge reads a character
      # taking coins or a thing as giving them, three times of three on the
      # probes; the receipts know which way it went.
      def received_this_turn?(npc, context, tcs, item_id: nil, coins: nil)
        (Array(context.turn_transcript&.tool_calls) + Array(tcs)).any? do |tc|
          next false if tc["result"].is_a?(::Hash) && tc["result"]["error"]
          case tc["name"]
          when "give_item"      then item_id && tc.dig("args", "to_id") == npc.id && tc.dig("args", "item_id") == item_id
          when "transfer_coins" then coins && tc.dig("args", "to_id") == npc.id && tc.dig("args", "amount") == coins
          when "buy_item"       then coins && tc.dig("result", "merchant_id") == npc.id && tc.dig("result", "price") == coins
          else false
          end
        end
      end

      # A reason for coins to leave this character toward the target: an open
      # coins debt to them, or a contest the target won against them in this
      # scene (the wager's payout).
      def coins_due?(npc, target, context)
        return true if ::Obligation.open_now.exists?(kind: "coins", debtor_id: npc.id, creditor_id: target.id)
        ledger = context.active_scene&.contest_ledger || {}
        target.is_a?(::Player) && ledger.any? { |key, payload| key.to_s.start_with?("#{npc.id}:") && payload.is_a?(::Hash) && payload["player_won"] && !payload["wager"] }
      end

      # The three gates on a thing brought out on the character's word
      # (Items::Offers): the trade allows the category, the label is a name,
      # the phase budget has room. Nil when it can be minted, else [kind,
      # message]. All final: a second answer cannot make a hoe a provision,
      # and a blank category is not a defect of form to bounce — it is the
      # judge's honest "not of my trade" (a lantern, a belt knife). Bounced
      # with the kinds named, the model relabels the thing to fit (probe
      # 2026-09-17: lantern and knife both became provisions; hands run 1
      # t17: a hoe became food). The line stands as a lapse.
      def things(a)
        Array(a["things"]).select { |t| t.is_a?(::Hash) && t["item"].to_s.strip != "" }
      end

      def thing_defect(t, act, npc, context)
        offers = ::Harness::Items::Offers
        cats   = offers.categories_for(npc, context.player_location)
        cat    = t["category"].to_s.strip
        return [ :refuse, "#{cat.inspect} is not a kind of thing" ] unless ::Harness::Items::Library::CATEGORIES.include?(cat)
        if SIGNIFICANT_KINDS.include?(cat)
          return [ :refuse, "#{npc.name}'s trade brings out no #{cat}#{cats.any? ? " (#{cats.join(', ')})" : ''}" ] unless cats.include?(cat)
        elsif !cats.include?(cat)
          return [ :refuse, "#{npc.name} would not have #{t['item'].inspect} at hand" ] unless at_hand?(context, npc, t, act)
        end
        # A description where a name was asked for is a defect of form, not
        # a judgement: "a coarse wool sack filled to the brim with pale salt
        # crystals" (hands run 6, t5) is a sack of salt the engine can mint.
        return [ :bounce, "`item` must be a name of a few words, not a description — #{t['item'].inspect}" ] unless offers.clean_label(t["item"])
        return [ :refuse, "#{npc.name} has brought out all they can this #{::Harness::Clock.phase(context.game_time)}" ] unless offers.budget_left?(npc, context.game_time)
        nil
      end

      # Would a person like this have this everyday thing about them? Asked
      # only for provisions and goods outside the trade's own kinds; a
      # sword outside the trade is refused before this is reached.
      def at_hand?(context, npc, t, act)
        props   = npc.properties.is_a?(::Hash) ? npc.properties : {}
        payload = {
          "you"   => { "name" => npc.name, "trade" => npc.subrole, "looks" => (props["appearance"] || props["physical"]).presence,
                       "carry" => npc.items.map(&:name).sort.presence,
                       "trade_brings_out" => ::Harness::Items::Offers.categories_for(npc, context.player_location) }.compact,
          "thing" => t["item"], "kind" => t["category"], "act" => act
        }
        raw = llm(context).complete(system: (@mint_prompt ||= File.read(MINT_PROMPT_PATH)), user: "INPUT:\n#{JSON.pretty_generate(payload)}",
                                    schema: MINT_SCHEMA, max_tokens: JUDGE_MAX_TOKENS, temperature: 0, thinking: false)
        out = parse_emit(raw)
        has = out.is_a?(::Hash) && out["has"] == true
        @logger.info { "[Runner conversation] #{npc.name} #{has ? 'has' : 'would not have'} #{t['item'].inspect} at hand (#{out.is_a?(::Hash) ? out['reasoning'] : 'unparseable'})" }
        has
      rescue StandardError => e
        @logger.warn { "[Runner conversation] at-hand judge failed for #{npc.name}: #{e.class}: #{e.message}" }
        false
      end

      # A give/attack target by id: the player or an NPC standing here.
      def present_by_id(id, context, player)
        return nil unless id.is_a?(::Integer)
        return player if id == player.id
        loc = context.player_location
        loc && ::Npc.find_by(id: id, location_id: loc.id)
      end

      # This seller's unsold things on the table here — and, for staff at
      # their own stocked venue, the shelf: those rows carry no seller id,
      # and shown an empty table Herewald "slid the wares forward" and the
      # act judge minted a second copper band beside the first (run 7 t4).
      def own_wares(npc, context)
        loc = context.player_location
        return [] unless loc
        at_post = npc.home_location_id == loc.id && loc.properties.is_a?(::Hash) && loc.properties["shop"].present?
        ::Item.where(location_id: loc.id).select { |i|
          props = i.properties.is_a?(::Hash) ? i.properties : {}
          props["for_sale"] && (props["seller_id"] == npc.id || (at_post && props["seller_id"].nil?))
        }
      end

      # Things lying here that are nobody's wares.
      def loose_here(context)
        loc = context.player_location
        return [] unless loc
        ::Item.where(location_id: loc.id).reject { |i| i.properties.is_a?(::Hash) && i.properties["for_sale"] }
      end

      # Where a leaving character goes: a nearby place by id, or — for null —
      # home when home is not here, else the place this one sits in. Nil
      # means nowhere to go (a defect, not a silent stay).
      def leave_destination(place_id, npc, context)
        loc = context.player_location
        return nil unless loc
        if place_id.nil?
          home = ::Location.find_by(id: npc.home_location_id)
          return home if home && home.id != loc.id
          return loc.parent
        end
        nearby_rows(context).find { |l| l.id == place_id }
      end

      # The exit: relocate, pin until the next phase boundary (the schedule
      # would otherwise snap them back at the next refresh), record a legible
      # departure, and drop them from the live roster so nothing later this
      # turn (initiative, a second speaker) addresses an empty stool.
      def leave!(npc, dest, context, player, tcs)
        from = context.player_location
        npc.update!(location_id: dest.id)
        ::Harness::Scene::Whereabouts.pin!(npc, dest, context.game_time)
        event = ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "local",
          location:  from,
          details:   { "narrative" => { "trigger" => "#{npc.name} leaves", "details" => "#{npc.name} leaves for #{dest.name}." } },
          participants: [ { character: npc, role: "actor" }, { character: player, role: "participant" } ]
        )
        context.active_scene&.remove_present!(npc.id)
        tcs << tool_call("npc_leave", { "character_id" => npc.id, "name" => npc.name, "to" => dest.name }, { "left" => true, "event_id" => event&.id })
        @logger.info { "[Runner conversation] #{npc.name} leaves for #{dest.name}" }
      end

      # REFLECTION — the knowledge write path. A second ask on the speaker's
      # still-hot voicing context: same system, same user prefix (KV-cache
      # reuse), plus a tail quoting what they just said and asking what they
      # claimed. The judgment is made WITH the speaker's recall/roster/thread
      # in view — a statement is only a NEW claim relative to what the speaker
      # could see. Extraction lands in Knowledge::Capture.ingest (routing,
      # realizers, dedup, revision — unchanged). Speaker attribution is
      # structural, not model-reported. Non-fatal.
      # Grammar contract for the voicing emit. required = thought + speak
      # ONLY: decliners stop after "speak": false exactly as the prompt
      # instructs, and speak-true-with-dialogue-absent stays GRAMMATICAL on
      # purpose — that shape is format loss of real content (the Rolf flake)
      # and keeps its one correction bounce. The deliberate escape hatch is
      # explicit prose: "" — a constrained emit backing out mid-object reads
      # as a break-off, not a defect (see apply_emit / emit_defect).
      # PROPERTY ORDER IS GRAMMAR. The hosted grammar compiler enforces the
      # schema's property order and its required set: after the last key the
      # model emits, a missing required key masks the closing brace, and the
      # only legal tokens left are whitespace. `subrole` is required (see
      # below) but the prompt asks for it only from unnamed figures; listed
      # after `doing` it was skipped and a third of all voicings ran into a
      # newline loop to the token ceiling and were dropped (2026-09-16, the
      # day the trailing `beat` array left the schema — it had been forcing
      # `subrole` out on the way to a key the model always wrote). Listed
      # before the keys every emit carries, the grammar forces it out while
      # the model still expects a key, and the brace is legal at the end.
      VOICING_SCHEMA = {
        "type" => "object",
        "properties" => {
          "thought" => { "type" => "string" },
          "speak"   => { "type" => "boolean" },
          "dialogue" => { "anyOf" => [ { "type" => "null" }, {
            "type" => "object",
            "properties" => { "summary" => { "type" => "string" }, "prose" => { "type" => "string" } },
            "required" => %w[summary prose], "additionalProperties" => false
          } ] },
          # The silent snub: a DECLINER may still visibly shift what they're
          # doing ("turns back to his ropes"). Optional — null/absent is the
          # normal answer; honored only on the decline path (speakers' doing
          # belongs to the taking-stock pass).
          "doing" => { "type" => %w[string null] }
        },
        "required" => %w[thought speak],
        "additionalProperties" => false
      }.freeze

      # Grammar contract for the act judge: one act, every binding field
      # required-nullable so the sampler answers each of them. Property
      # order is grammar on the hosted sampler: `reasoning` comes first so
      # the judge names what the hands do before it commits to an act —
      # thinking mode is off (ruled 2026-09-16: 3–10 s and 250–480 tokens
      # per speaker against ~1 s and ~50 without; a directed clause is the
      # audit trail instead).
      ACT_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "act"      => { "type" => "string", "enum" => ACT_KINDS },
          "to_id"    => { "type" => %w[integer null] },
          "coins"    => { "type" => %w[integer null] },
          "item_id"  => { "type" => %w[integer null] },
          # A list: "a short sword and a mail coif" set out in one line filled
          # one slot with both names and no kind, and the coif never had a row
          # (hands run 9 t4). The kind is an enum, not a string: offered the
          # kinds the judge picks one; asked to name one it left the field
          # blank for a waterskin (run 7 t25).
          "things"   => { "type" => "array", "items" => {
            "type" => "object",
            "properties" => { "item" => { "type" => "string" }, "category" => { "enum" => ::Harness::Items::Library::CATEGORIES } },
            "required" => %w[item category], "additionalProperties" => false
          } },
          "place_id" => { "type" => %w[integer null] }
        },
        "required" => %w[reasoning act to_id coins item_id things place_id],
        "additionalProperties" => false
      }.freeze

      # Grammar contracts for the two reflection judges (llama.cpp
      # json_schema → GBNF; hosted json_schema). The sampler cannot answer in
      # the dialogue schema, emit prose, or truncate mid-object — the bounce
      # becomes a dead backstop instead of a 3-second tax. Shapes mirror
      # knowledge_reflection.txt (claims) and knowledge_ledger.txt (bargains).
      NULLABLE_STR = { "type" => %w[string null] }.freeze
      FACT_ABOUT   = %w[the_world a_price_or_stock a_debt_or_purse this_moment the_player].freeze
      ADDITION_SCHEMA = lambda { |id_key|
        { "type" => "array", "items" => {
          "type" => "object",
          "properties" => { id_key => { "type" => "integer" }, "content" => { "type" => "string" } },
          "required" => [ id_key, "content" ],
          "additionalProperties" => false
        } }
      }
      WORLD_SCHEMA = {
        "type" => "object",
        "properties" => {
          "facts" => { "type" => "array", "items" => {
            "type" => "object",
            "properties" => {
              # What the fact is ABOUT comes first: of 23 facts filed over
              # runs 6–8, 8 were prices or stock, 6 debts or purses, 7 the
              # moment or the player — state the till and the ledger own,
              # returned to the voice as TRUE knowledge while the world moved
              # on (context audit 2026-09-20). Only the world is written.
              # Scope is not asked (a spoken claim is at most what this town
              # believes). min_int stays: Knowledge::Query gates recall on it
              # (the wit it takes to know a piece of lore) — a feature not yet
              # exercised, kept by ruling 2026-09-22.
              "about"    => { "type" => "string", "enum" => FACT_ABOUT },
              "content"  => { "type" => "string" },
              "concerns" => { "type" => "array", "items" => { "type" => "string" } },
              "min_int"  => { "type" => %w[integer null] },
              "when"     => NULLABLE_STR
            },
            "required" => %w[about content concerns min_int when],
            "additionalProperties" => false
          } },
          "event_additions" => ADDITION_SCHEMA.call("event_id"),
          "fact_additions"  => ADDITION_SCHEMA.call("fact_id"),
          "retold"          => { "type" => "array", "items" => { "type" => "integer" } },
          "people" => { "type" => "array", "items" => {
            "type" => "object",
            "properties" => {
              "name" => { "type" => "string" }, "subrole" => NULLABLE_STR,
              "gist" => { "type" => "string" }, "at_location" => NULLABLE_STR
            },
            "required" => %w[name subrole gist at_location],
            "additionalProperties" => false
          } },
          "places" => { "type" => "array", "items" => {
            "type" => "object",
            "properties" => { "name" => { "type" => "string" }, "about" => { "type" => "string" } },
            "required" => %w[name about],
            "additionalProperties" => false
          } }
        },
        "required" => %w[facts event_additions fact_additions retold people places],
        "additionalProperties" => false
      }.freeze
      # THE LEDGER's four grammars (property order is grammar: `reasoning`
      # first, every field required). Shapes mirror ledger_*.txt.
      LEDGER_STRUCK_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning"   => { "type" => "string" },
          # What the turn IS, before whether it struck: asked struck-or-not
          # alone the judge called a loaf handed over, "are we square?", a
          # look around and a wager's payout bargains — 13 false of 28 on
          # hands run 8, and every phantom debt of that run; classing the
          # turn first, 3 of 28, and 8 of 10 disagreements on runs 6–7.
          "turn_is"     => { "type" => "string", "enum" => %w[new_terms carrying_out talk wager] },
          "struck"      => { "type" => "boolean" },
          "proposed_by" => { "type" => "string", "enum" => %w[player you none] },
          "accepted_by" => { "type" => "string", "enum" => %w[player you none] }
        },
        "required" => %w[reasoning turn_is struck proposed_by accepted_by],
        "additionalProperties" => false
      }.freeze
      LEDGER_TERMS_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "sides" => { "type" => "array", "items" => {
            "type" => "object",
            "properties" => {
              "who"    => { "type" => "string", "enum" => %w[player you] },
              "kind"   => { "type" => "string", "enum" => %w[coins deed meet] },
              "amount" => { "type" => %w[integer null] },
              "terms"  => { "type" => "string" }
            },
            "required" => %w[who kind amount terms],
            "additionalProperties" => false
          } },
          "due"   => NULLABLE_STR,
          "where" => NULLABLE_STR
        },
        "required" => %w[reasoning sides due where],
        "additionalProperties" => false
      }.freeze
      LEDGER_DELIVERED_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "delivered" => { "type" => "array", "items" => { "type" => "integer" } }
        },
        "required" => %w[reasoning delivered],
        "additionalProperties" => false
      }.freeze
      LEDGER_DISCHARGED_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning"  => { "type" => "string" },
          "discharged" => { "type" => "array", "items" => {
            "type" => "object",
            "properties" => {
              "id"  => { "type" => "integer" },
              "how" => { "type" => "string", "enum" => %w[released delivered] }
            },
            "required" => %w[id how],
            "additionalProperties" => false
          } }
        },
        "required" => %w[reasoning discharged],
        "additionalProperties" => false
      }.freeze
      WORLD_JUDGE  = { path: REFLECTION_PROMPT_PATH, schema: WORLD_SCHEMA,  keys: %w[facts event_additions fact_additions retold people places] }.freeze
      LEDGER_SAMPLING   = { temperature: 0, thinking: false }.freeze
      LEDGER_STRUCK     = { path: LEDGER_STRUCK_PATH,     schema: LEDGER_STRUCK_SCHEMA,     keys: %w[struck],     sampling: LEDGER_SAMPLING }.freeze
      LEDGER_TERMS      = { path: LEDGER_TERMS_PATH,      schema: LEDGER_TERMS_SCHEMA,      keys: %w[sides],      sampling: LEDGER_SAMPLING }.freeze
      LEDGER_DELIVERED  = { path: LEDGER_DELIVERED_PATH,  schema: LEDGER_DELIVERED_SCHEMA,  keys: %w[delivered],  sampling: LEDGER_SAMPLING }.freeze
      # RELEASE? — the one confirm question behind a "released" the discharge
      # judge answers for a debt the speaker owes: the player's words alone.
      # "I'll take those three coins" was read as letting the debt go, six
      # times of six under every framing tried (run 7 t21), and a debt the
      # player wanted collected vanished.
      LEDGER_RELEASE_PATH   = Rails.root.join("lib/harness/prompts/ledger_release.txt")
      LEDGER_RELEASE_SCHEMA = { "type" => "object", "properties" => { "reasoning" => { "type" => "string" }, "lets_go" => { "type" => "boolean" } },
                                "required" => %w[reasoning lets_go], "additionalProperties" => false }.freeze
      LEDGER_RELEASE = { path: LEDGER_RELEASE_PATH, schema: LEDGER_RELEASE_SCHEMA, keys: %w[lets_go], sampling: { temperature: 0, thinking: false } }.freeze
      LEDGER_DISCHARGED = { path: LEDGER_DISCHARGED_PATH, schema: LEDGER_DISCHARGED_SCHEMA, keys: %w[discharged], sampling: LEDGER_SAMPLING }.freeze

      # REFLECTION — two judges, each on a CLEAN context. The old single pass
      # rode the voicing prefix and judged five things at once; that was the
      # fig-caravan lapse (a recalled event restated as a standing fact with
      # "this morning" baked in), and hosted inference reports no prefix
      # cache, so the ride bought nothing. WORLD: the speaker's own line
      # against the records they were handed → facts / additions / people /
      # places. LEDGER: the exchange as a bargain → deals / discharged, by
      # four narrow judges with early exits (see `bargains`).
      # Capture stays the single writer; `fed` maps the judges' record ids
      # back to rows. unprompted: the line came from the initiative pass —
      # the player spoke to no one this turn, which the deals writer holds
      # against any bargain naming them as debtor.
      def reflect_knowledge(context, v, emit, fed, unprompted: false, tool_calls: nil)
        prose = emit.dig("dialogue", "prose").to_s.strip
        return if prose.empty?
        fed   ||= {}
        speaker = v[:char]["name"]
        did     = Array(emit["did"]).map(&:to_s).reject(&:empty?)
        world   = judge(context, speaker, WORLD_JUDGE, world_payload(v, prose, did, fed))
        ledger  = bargains(context, v, prose, fed, tool_calls, emit)
        return if world.nil? && ledger.nil?
        payload = (world || {}).slice(*WORLD_JUDGE[:keys]).merge(ledger || {})
        ::Harness::Knowledge::Capture.ingest(
          payload:   payload,
          speaker:   speaker,
          llm:       llm(context),
          location:  context.player_location,
          game_time: context.game_time,
          context:   context,   # enables person/place realization (the single entity pipe)
          player_spoke: !unprompted,
          tool_calls: tool_calls,
          records:   fed.slice("events", "facts"),
          logger:    @logger
        )
      rescue StandardError => e
        # The frame rides along: six silent losses of a speaker's reflection
        # logged only "TypeError: String does not have #dig method" and
        # nothing to find it by (2026-09-12).
        @logger.warn { "[Runner conversation] reflection capture failed for #{v[:char]['name']}: #{e.class}: #{e.message} @ #{Array(e.backtrace).first(2).join(' <- ')}" }
      end

      # One judge call with its one correction bounce: when the model answers
      # in the dialogue shape (or garbage), re-ask once with the defect named
      # instead of dropping the claims outright. nil = both attempts failed.
      def judge(context, speaker, spec, payload)
        system = judge_prompt(spec)
        user   = "INPUT:\n#{JSON.pretty_generate(payload)}"
        raw = ::Harness::CostTracker.in_subsystem(:knowledge_capture) do
          llm(context).complete(system: system, user: user, schema: spec[:schema], max_tokens: JUDGE_MAX_TOKENS, **spec.fetch(:sampling, {}))
        end
        parsed = parse_reflection(raw)
        if (defect = judge_defect(parsed, spec[:keys]))
          @logger.warn { "[Runner conversation] #{spec[:keys].first} judge for #{speaker} #{defect} — retrying once" }
          raw = ::Harness::CostTracker.in_subsystem(:knowledge_capture) do
            llm(context).complete(system: system, user: "#{user}\n\n#{judge_retry_tail(defect, raw, spec[:schema]['properties'].keys.first)}", schema: spec[:schema], max_tokens: JUDGE_MAX_TOKENS, **spec.fetch(:sampling, {}))
          end
          parsed = parse_reflection(raw)
          if (still = judge_defect(parsed, spec[:keys]))
            @logger.warn { "[Runner conversation] #{spec[:keys].first} judge for #{speaker} #{still} on retry — claims dropped" }
            return nil
          end
        end
        parsed
      end

      # What the WORLD judge sees: the line, the acts, and the records the
      # speaker was handed, numbered 1..n per kind (records_given) so an
      # addition can name its record; Capture maps the numbers back to rows.
      # records_given ids are ONE space across both lists — events 1..E, facts
      # E+1.. — so a detail the judge files under the wrong list still names
      # an unambiguous record (Capture resolves by id, not by list). Separate
      # 1-based lists collided: event 1 and fact 1 in the same payload, and a
      # fence-work detail landed on the daughter-argument event (2026-09-12).
      def world_payload(v, prose, did, fed)
        events = Array(fed["events"])
        given  = ->(pairs, offset) { Array(pairs).each_with_index.map { |(_, text), i| { "id" => offset + i + 1, "text" => text } } }
        {
          "you"            => { "name" => v[:char]["name"], "subrole" => v[:char]["subrole"] }.compact,
          "said"           => prose,
          "did"            => did,
          "records_given"  => { "events" => given.call(events, 0), "facts" => given.call(fed["facts"], events.size) },
          "others_present" => Array(fed["others"]),
          "known_places"   => Array(fed["places"])
        }
      end

      # THE LEDGER — four narrow judges with early exits, replacing the one
      # bargains judge that did recognition, attribution, terms and
      # discharges in a single answer and got the side wrong twice in hands
      # runs 4 and 5 (a side already handed over booked as owed; a
      # bystander's "Left." re-booking a standing swap the other way round).
      # Struck? — who proposed, who accepted — exit on no. Terms as sides →
      # which sides this turn's receipts already carried out → the rest are
      # debts. Discharges by id, only when debts stand between the speaker
      # and the player. Capture stays the writer; this returns its
      # `deals` / `discharged` contract.
      # The gate and the terms judge see only the exchange just before this
      # turn: given three, the gate fished out a proposal two turns old and
      # struck it again (probe on hands run 4 t18, the errand already on the
      # books). Terms older than that get restated by the people closing.
      LEDGER_THREAD = 1
      def bargains(context, v, prose, fed, tcs, emit = {})
        player = ::Player.first
        return nil unless player
        name  = v[:char]["name"]
        debts = pair_debts(v[:char]["id"], player.id, context.game_time)
        base  = {
          "you"             => { "name" => name },
          "player"          => { "name" => player.name },
          "exchange"        => Array(fed["thread"]).last(LEDGER_THREAD),
          "player_said_now" => fed["input"],
          "you_said"        => prose,
          "this_turn"       => outcome_this_turn(context, tcs, emit)
        }
        moved      = moved_this_turn?(context, tcs)
        deals      = struck_deals(context, name, player, base, debts, moved, receipts_this_turn(context, tcs), wager_coins_paid(context.active_scene, v[:char]["id"]))
        discharged = debts.empty? ? [] : discharged_debts(context, name, base, debts, moved, tcs, v[:char]["id"], player)
        return nil if deals.empty? && discharged.empty?
        { "deals" => deals, "discharged" => discharged }
      end

      # Coin stakes a wager already moved between this character and the
      # player this scene.
      def wager_coins_paid(active, id)
        (active&.contest_ledger || {}).filter_map do |key, p|
          p["paid_coins"] if p.is_a?(::Hash) && p["wager"] && key.to_s.start_with?("#{id}:") && p["paid_coins"].is_a?(::Integer)
        end
      end

      # Only a transfer can carry a side out: a table laid or a wager voided
      # is a receipt, not a delivery, and asks the delivered judge nothing.
      DELIVERY_CALLS = %w[give_item trade_items transfer_coins buy_item sell_item drop].freeze
      def moved_this_turn?(context, tcs)
        (Array(context.turn_transcript&.tool_calls) + Array(tcs)).any? { |tc| DELIVERY_CALLS.include?(tc["name"]) }
      end

      def struck_deals(context, name, player, base, debts, moved, receipts, wager_coins = [])
        gate = judge(context, name, LEDGER_STRUCK, base.merge("open_debts" => debts.map { |d| d["line"] }))
        return [] unless gate
        prop, acc = gate["proposed_by"].to_s, gate["accepted_by"].to_s
        unless gate["struck"] == true && gate["turn_is"] == "new_terms" && %w[player you].include?(prop) && %w[player you].include?(acc) && prop != acc
          @logger.info { "[Runner conversation] #{name} ledger: nothing struck (#{gate['reasoning']})" }
          return []
        end
        @logger.info { "[Runner conversation] #{name} ledger: struck — proposed by #{prop}, accepted by #{acc} (#{gate['reasoning']})" }
        terms = judge(context, name, LEDGER_TERMS, base.except("this_turn").merge("proposed_by" => prop, "accepted_by" => acc))
        sides = Array(terms && terms["sides"]).select do |x|
          x.is_a?(::Hash) && %w[player you].include?(x["who"]) && %w[coins deed meet].include?(x["kind"].to_s) && x["terms"].to_s.strip != ""
        end
        # A paid wager restated as a debt. "You owe me from the wager" / "Paid
        # — matter closed" struck a fresh two-coin debt three times of three
        # under every prompt tried, and the next turn's initiative paid the
        # wager out a second time (hands run 6, t13–t16). The dice settled
        # it: a coins side matching what a wager already moved between the
        # pair this scene is that wager, not a bargain.
        sides = sides.reject do |x|
          next false unless x["kind"] == "coins" && wager_coins.include?(x["amount"])
          @logger.info { "[Runner conversation] #{name} ledger: coins side of #{x['amount']} is the wager the dice already paid — refused" }
          true
        end
        return [] if sides.empty?
        done = []
        if moved
          numbered = sides.each_with_index.map { |x, i| { "n" => i + 1, "who" => x["who"], "kind" => x["kind"], "amount" => x["amount"], "terms" => x["terms"] } }
          # Receipts only — not the refusal facts. Beside "You buy the woven
          # blanket for 4 coins." sat "Nothing changed hands: give: Mildryth
          # owes Wyot nothing…" (the act judge had read her taking coins as
          # giving them), and the delivered judge took the refusal as the
          # blanket not delivered, three times of three (hands run 6, t11).
          d = judge(context, name, LEDGER_DELIVERED, { "you" => base["you"], "sides" => numbered, "this_turn" => receipts })
          done = Array(d && d["delivered"]).select { |n| n.is_a?(::Integer) }
        end
        sides.each_with_index.filter_map do |x, i|
          if done.include?(i + 1)
            @logger.info { "[Runner conversation] #{name} ledger: side #{i + 1} (#{x['who']}: #{x['terms']}) carried out this turn" }
            next
          end
          owes, owed = x["who"] == "you" ? [ name, player.name ] : [ player.name, name ]
          { "who_owes" => owes, "owed_to" => owed, "kind" => x["kind"], "amount" => x["amount"], "terms" => x["terms"],
            "due" => terms["due"], "where" => terms["where"], "proposed_by" => prop, "accepted_by" => acc }
        end
      end

      # "delivered" is a claim about the receipts: on a turn where nothing
      # changed hands it is refused (probe on hands run 4 t18: the debtor's
      # own narration of an errand, no receipt, judged delivered).
      def discharged_debts(context, name, base, debts, moved, tcs = [], speaker_id = nil, player = nil)
        d = judge(context, name, LEDGER_DISCHARGED, base.except("exchange").merge("open_debts" => debts))
        Array(d && d["discharged"]).filter_map do |x|
          next unless x.is_a?(::Hash) && (debt = debts.find { |o| o["id"] == x["id"] })
          row = ::Obligation.find_by(id: x["id"])
          case x["how"]
          when "delivered"
            # A receipt of the debtor's own hands this turn, not any receipt:
            # "Mara pays you 3 coins" was taken as the player's bundle
            # delivered (run 7 t21 retry).
            unless moved && row && delivered_by?(row, context, tcs)
              @logger.info { "[Runner conversation] #{name} ledger: debt ##{x['id']} judged delivered with no receipt of the debtor's this turn — refused" }
              next
            end
          when "released"
            # A debt the speaker owes is released only by the player's words —
            # one confirm question on those words alone.
            if row && speaker_id && row.debtor_id == speaker_id && !release_confirmed?(context, name, debt["line"], base["player_said_now"])
              @logger.info { "[Runner conversation] #{name} ledger: debt ##{x['id']} judged released, but the player's words do not let it go — refused" }
              next
            end
          end
          { "id" => x["id"], "how" => x["how"].to_s }
        end
      end

      def release_confirmed?(context, name, line, player_said)
        return false if player_said.to_s.strip.empty?
        r = judge(context, name, LEDGER_RELEASE, { "debt" => line, "player_said" => player_said })
        r.is_a?(::Hash) && r["lets_go"] == true
      end

      # Did the debtor's own hands move something this turn: a give, a drop, a
      # coin transfer, a purchase or a trade of theirs among the receipts.
      # A receipt of the debtor's own hands, of the debt's own kind: a deed
      # (work, goods, a thing to hand over) is delivered by a thing leaving
      # the debtor's hands, never by their coins — "You buy the sawblade for
      # 4 coins" was taken as the buyer's day of hauling delivered, against
      # the judge's own reasoning (hands run 10 t3). Coins settle by the
      # transfer itself; a meeting is the schedule's to settle, not a receipt's.
      def delivered_by?(row, context, tcs)
        debtor_id = row.debtor_id
        (Array(context.turn_transcript&.tool_calls) + Array(tcs)).any? do |tc|
          next false if tc["result"].is_a?(::Hash) && tc["result"]["error"]
          case row.kind
          when "deed"
            case tc["name"]
            when "give_item"   then tc.dig("args", "from_id") == debtor_id
            when "drop"        then tc.dig("args", "by_character_id") == debtor_id
            when "trade_items" then (tc.dig("args", "trader_id") || ::Player.first&.id) == debtor_id
            when "sell_item"   then tc.dig("result", "seller_id") == debtor_id
            else false
            end
          when "coins"
            case tc["name"]
            when "transfer_coins" then tc.dig("args", "from_id") == debtor_id
            when "buy_item"       then tc.dig("result", "buyer_id") == debtor_id
            else false
            end
          else false
          end
        end
      end

      # The standing rows between this character and the player — open, and
      # broken (a broken promise can still be made good by a receipt or let
      # go by the player's words; deeds-1 t22: the net handed over, the
      # broken row a corpse on the sheet) — by id, each rendered from the
      # character's seat in third person. Kept rows stay out: the engine
      # hands those over itself, and a word must not settle them first.
      def pair_debts(id, player_id, now)
        return [] unless id
        name = ::Character.find_by(id: id)&.name
        ::Obligation.where(status: %w[open broken])
                    .where("(debtor_id = ? AND creditor_id = ?) OR (debtor_id = ? AND creditor_id = ?)", id, player_id, player_id, id)
                    .order(:id).map { |o| { "id" => o.id, "line" => o.line_for(id, now: now, name: name) } }
      rescue ::StandardError
        []
      end

      # <<...>> markers are runtime substitutions owned by THIS runner —
      # deliberately not {{...}}, which is Prompts::Preamble's vocabulary
      # namespace (its integration spec rejects unexpanded {{ in prompt files).
      def judge_prompt(spec)
        @judge_prompts ||= {}
        @judge_prompts[spec[:path]] ||= File.read(spec[:path]).sub("<<SUBROLES>>") { ::Harness::Vocations.all.join(", ") }
      end

      def judge_defect(payload, keys)
        return "unparseable" unless payload.is_a?(::Hash)
        return "answered in DIALOGUE schema" if payload.key?("speak") && keys.none? { |k| payload.key?(k) }
        nil
      end

      def judge_retry_tail(defect, raw, first_key)
        "--- RETRY ---\nYour previous output was rejected: #{defect}.\nPrevious output:\n#{echo_for_retry(raw)}\n\n" \
        "The dialogue turn is OVER. Output ONLY the JSON described above — no \"thought\", no \"speak\" — beginning with {\"#{first_key}\":"
      end

      # TAKING STOCK — two clean judges after a speaker's line, replacing
      # the one that rode the voicing prefix and answered five things at
      # once. INNER: disposition (one ladder step), mood, agenda, read
      # through the persona with the settled verdict as a fact. HANDS: the
      # activity the body settles into, which the eyes render on later
      # looks. Both see the turn's receipts, so a knife the act judge
      # refused is not "gone from his belt" (hands run 1, t10) and a walk
      # the engine never made is not in the doing (hands run 4, t18).
      # Personality is INPUT only — it conditions the shift, never changes.
      # A garbage answer is skipped outright (held state is always safe).
      STOCK_INNER_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning"   => { "type" => "string" },
          "disposition" => { "type" => "string", "enum" => %w[hold warmer colder] },
          "mood"        => { "type" => %w[string null] },
          "agenda"      => { "type" => "string", "enum" => %w[pursue resolved abandoned] }
        },
        "required" => %w[reasoning disposition mood agenda],
        "additionalProperties" => false
      }.freeze
      STOCK_HANDS_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "doing"     => { "type" => %w[string null] }
        },
        "required" => %w[reasoning doing],
        "additionalProperties" => false
      }.freeze
      STOCK_SAMPLING = { temperature: 0.3, thinking: false }.freeze

      def reevaluate_state(context, v, emit, active, fed, tcs, contest: nil)
        return unless active
        prose = emit.dig("dialogue", "prose").to_s.strip
        return if prose.empty?
        id    = v[:char]["id"]
        props = ::Npc.find_by(id: id)&.properties
        you   = { "name" => v[:char]["name"], "subrole" => v[:char]["subrole"],
                  "personality" => (props["personality"] if props.is_a?(::Hash)),
                  "disposition" => active.disposition_for(id), "mood" => active.state_for(id),
                  "agenda" => active.agenda_for(id), "doing" => active.doing_for(id) }.compact
        base  = { "you" => you, "player_said_now" => fed && fed["input"], "you_said" => prose, "this_turn" => outcome_this_turn(context, tcs, emit) }.compact
        base["contest"] = contest[:payload] if contest && contest[:payload] && contest[:target_id] == id

        inner = stock_judge(context, STOCK_INNER_PATH, STOCK_INNER_SCHEMA, base.merge("you" => you.except("doing")))
        if inner
          active.shift_disposition!(id, inner["disposition"]) if %w[warmer colder].include?(inner["disposition"])
          if inner["mood"].is_a?(::String) && !inner["mood"].strip.empty?
            # Stored raw, a ladder word echoed back renders "guarded — guarded — …".
            flavor = inner["mood"].strip.sub(/\A(?:#{::Harness::Scene::DISPOSITIONS.join('|')})\s*—\s*/i, "")
            active.update_state!(id, flavor) unless flavor.empty?
          end
          active.clear_agenda!(id) if %w[resolved abandoned].include?(inner["agenda"]) && active.agenda_for(id)
        end

        hands = stock_judge(context, STOCK_HANDS_PATH, STOCK_HANDS_SCHEMA, base.except("player_said_now", "contest").merge("you" => you.slice("name", "subrole", "doing")))
        # The activity microbeat: written silently (the staged line already
        # voiced the change this turn); perception reads it on later looks.
        # The judge often hands the current doing back verbatim. That is a
        # hold, not a shift: stored as one it dirtied the voicing's copy and
        # logged a shift the eyes never saw (probe 10, 2026-09-12).
        doing = hands && hands["doing"].is_a?(::String) ? hands["doing"].strip : ""
        doing = "" if doing == active.doing_for(id).to_s
        active.update_doing!(id, doing) unless doing.empty?

        @logger.info do
          "[Runner conversation] #{v[:char]['name']} takes stock: disposition=#{inner ? inner['disposition'] : 'held'}" \
            " (now #{active.disposition_for(id)}) mood #{inner && inner['mood'] ? 'refreshed' : 'held'}" \
            " agenda=#{inner ? inner['agenda'] : 'held'} doing #{doing.empty? ? 'held' : 'shifted'}"
        end
      rescue ::StandardError => e
        @logger.warn { "[Runner conversation] taking stock failed for #{v[:char]['name']}: #{e.class}: #{e.message}" }
      end

      # The engine's outcome for this speaker: the turn's receipts, and the
      # refusal of their own line's act when there was one — an empty list
      # said too little (probe: a refused knife still "handed over" in the
      # taking-stock's doing and mood).
      def outcome_this_turn(context, tcs, emit)
        lines = engine_this_turn(context, tcs)
        lines += [ "Nothing changed hands: #{emit['not_done']}." ] if emit.is_a?(::Hash) && emit["not_done"].to_s.strip != ""
        lines
      end

      def stock_judge(context, path, schema, payload)
        @stock_prompts ||= {}
        system = (@stock_prompts[path] ||= File.read(path))
        raw = ::Harness::CostTracker.in_subsystem(:mood_reevaluation) do
          llm(context).complete(system: system, user: "INPUT:\n#{JSON.pretty_generate(payload)}", schema: schema, max_tokens: JUDGE_MAX_TOKENS, **STOCK_SAMPLING)
        end
        out = ::Harness::LLM::JsonResponse.parse(raw)
        return out if out.is_a?(::Hash) && (schema["properties"].keys - %w[reasoning]).any? { |k| out.key?(k) }
        @logger.warn { "[Runner conversation] #{File.basename(path, '.txt')} unparseable — state held" }
        nil
      rescue ::JSON::ParserError
        @logger.warn { "[Runner conversation] #{File.basename(path, '.txt')} unparseable — state held" }
        nil
      end

      # Malformed JSON must reach the bounce as a nil payload ("unparseable"),
      # not raise past it into reflect_knowledge's blanket rescue — that path
      # dropped a spoken deal with zero retries (the Bodil charm-meet).
      def parse_reflection(raw)
        ::Harness::LLM::JsonResponse.parse(raw)
      rescue ::JSON::ParserError
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
