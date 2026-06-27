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
    # (resolve_call → resolve), asserted ignorance (→ personal event), a durable
    # beat (memorable → propose_event), and a named person (claims → Realizer).
    class Conversation < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/conversation.txt")
      EVENT_SUMMARY_CAP = 10
      EVENT_TEXT_CAP = 220
      THREAD_CAP  = 6
      THREAD_CHARS = 700
      MAX_SPEAKERS = 2

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

        spoken     = 0
        parsed_any = false
        poll_order(present, extras, input, step).each do |v|
          break if spoken >= MAX_SPEAKERS
          emit = voice_one(context, input, step, player, v, roster, thread, resolver, tcs, active)
          next unless emit
          parsed_any = true
          spoken += 1 if apply_emit(resolver, context, scene, emit, v, player, promo, tcs)
        end

        return redispatch("conversation emit unparseable", tcs) unless parsed_any
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
        named + rest + Array(extras).each_with_index.map { |desc, i| { kind: :extra, index: i, desc: desc } }
      end

      def addressed_by_name?(char, hay)
        first = char["name"].to_s.split.first.to_s.downcase
        sub   = char["subrole"].to_s.downcase.tr("_", " ")
        (first.length >= 2 && hay.include?(first)) || (sub.length >= 2 && hay.include?(sub))
      end

      # Voice ONE character. The call sees this character's own events (or, for
      # an extra, just its description), the public roster of who else is here,
      # and the shared thread — never anyone else's events.
      def voice_one(context, input, step, player, v, roster, thread, resolver, tcs, active)
        you =
          if v[:kind] == :extra
            { "ambient" => true, "index" => v[:index], "desc" => v[:desc] }
          else
            npc_knowledge(resolver, v[:char], tcs, active)
          end
        others = v[:kind] == :npc ? roster.reject { |r| r["name"] == v[:char]["name"] } : roster
        user = JSON.pretty_generate(
          "you"             => you,
          "others_present"  => others,
          "exchange_so_far" => thread,
          "player"          => { "id" => player.id, "name" => player.name },
          "player_input"    => input,
          "intent"          => step&.intent
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
        engaged = emit["speak"] || prose != "" || emit["resolve_call"] || emit["ignorance"] || emit["claims"] || emit["memorable"]
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
        commit_claim(context, emit["claims"], actor_id, tcs)
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
      def npc_knowledge(resolver, char, tcs, active)
        res, _ = execute_tool(resolver, "query_events", { "for_holder_id" => char["id"], "limit" => EVENT_SUMMARY_CAP }, into: tcs)
        events = Array(res.is_a?(Hash) ? res["events"] : res)
          .map { |e| event_text(e) }
          .reject(&:empty?)
        props = ::Npc.find_by(id: char["id"])&.properties
        {
          "id"          => char["id"],
          "name"        => char["name"],
          "subrole"     => char["subrole"],
          "lens"        => char["lens"],
          "personality" => (props["personality"] if props.is_a?(::Hash)),
          "mood"        => active&.state_for(char["id"]),
          "agenda"      => active&.agenda_for(char["id"]),
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

      # GROUND v0 — realize a named person this character introduced into a
      # grounded row so it isn't a ghost (a name in one line with no row behind
      # it). The speaker is this character. Failure is non-fatal.
      def commit_claim(context, claim, actor_id, tcs)
        return unless claim.is_a?(Hash) && claim["name"].to_s.strip != ""
        speaker = ::Npc.find_by(id: actor_id)
        res = ::Harness::NarrativeShift::Realizer.run(claim: claim, speaker: speaker, context: context, logger: @logger)
        tcs << tool_call("realize_claim", claim, res || { "error" => "claim realize returned nil" })
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
