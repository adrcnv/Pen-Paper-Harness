module Harness
  module Runners
    # The player speaks to / asks / persuades the NPC(s) present. Structured
    # emit: ONE LLM call returns dialogue + an optional roll + asserted
    # ignorance as JSON; the runner commits each via tools in Ruby. This makes
    # the propose_event-as-narration runaway STRUCTURALLY impossible — at most
    # one event per responding NPC (+ optional roll + ignorance), never a
    # 20-call spray.
    #
    # Step-2 scope: speech (dialogue_events → propose_event), persuasion
    # (resolve_call → resolve), asserted ignorance (→ personal propose_event).
    # Disclosed-past-facts (the backward two-event dance) and supplements are
    # deferred to playtest-driven refinement.
    class Conversation < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/conversation.txt")
      MAX_NPCS = 4
      EVENT_SUMMARY_CAP = 10

      def run(context:, scene:, input:, step:)
        present = Array(scene["present_characters"]).first(MAX_NPCS)
        return redispatch("no NPC present to converse with") if present.empty?

        player = ::Player.first
        return redispatch("no player row") unless player

        resolver = resolver_for(context)
        tcs = []
        promo = {} # extra_index → promoted character_id (memoized across commits)

        npcs = present.map { |c| npc_knowledge(resolver, c, tcs, context.active_scene) }
        emit = converse(context, input, step, player, npcs, scene)
        return redispatch("conversation emit unparseable", tcs) unless emit

        commit_resolve(resolver, context, scene, emit["resolve_call"], player, promo, tcs)
        stage_dialogue(resolver, context, scene, emit["dialogue_events"], player, promo, tcs)
        commit_memorable(resolver, emit["memorable"], player, present, tcs)
        commit_ignorance(resolver, emit["ignorance"], player, present, tcs)
        commit_claims(context, emit["claims"], present, tcs)

        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      private

      # Prefetch what this NPC could plausibly know (Ruby/SQL, no LLM) AND who
      # they are to voice — personality (stored at materialization), current mood
      # and scene agenda (seeded at scene entry). Without these the model voices
      # a bare subrole and re-improvises the character every turn (the "drunk
      # patron drifts into town-enforcer" failure). The data already exists; this
      # just exposes it to the context that animates them.
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
      # {"narrative" => {"trigger", "details"}}. The old code read top-level
      # "trigger"/"summary"/"details" (none of which exist there), fell back to
      # `details.to_s`, and truncated the Ruby-inspect string mid-word at 120
      # chars — handing the model garbage like `{"summary" => "The Great Silt`.
      # That's why a barkeep sitting on the founding-of-the-town event still
      # had "nothing interesting" to say.
      EVENT_TEXT_CAP = 220
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

      def converse(context, input, step, player, npcs, scene)
        user = JSON.pretty_generate(
          "exchange_so_far" => conversation_thread(context),
          "player_input" => input,
          "intent"       => step&.intent,
          "player"       => { "id" => player.id, "name" => player.name },
          "npcs"         => npcs,
          "present_extras" => extras_for_emit(scene)
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_conversation) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner conversation] emit failed: #{e.class}: #{e.message}" }
        nil
      end

      # The scene's thread up to now — the prior input→narration pairs the model
      # has been blind to. This is the fix for the conversation runner reasoning
      # in a vacuum: with the exchange in hand it holds the addressee, reacts to
      # what was actually said, and stops repeating itself. Runners execute
      # BEFORE this turn's narration is appended, so `narrations` is exactly the
      # conversation up to (not including) the current line. Capped + truncated
      # to keep the local model's context lean — enough to react, not the saga.
      THREAD_CAP  = 6
      THREAD_CHARS = 700
      def conversation_thread(context)
        active = context.active_scene
        return [] unless active
        Array(active.narrations).last(THREAD_CAP).map do |h|
          { "player" => h["input"].to_s, "scene" => h["narration"].to_s[0, THREAD_CHARS] }
        end
      end

      # Index present_extras so the model can reference an ambient figure it
      # wants to address/promote by its position in this list.
      def extras_for_emit(scene)
        Array(scene && scene["present_extras"]).each_with_index.map { |d, i| { "index" => i, "desc" => d } }
      end

      def commit_resolve(resolver, context, scene, rc, player, promo, tcs)
        return unless rc.is_a?(Hash) && rc["action"]
        target_id = rc["target_id"]
        if target_id.nil? && rc["target_extra_index"].is_a?(Integer)
          target_id = promote_extra(resolver, context, scene, rc["target_extra_index"], rc["target_subrole"], into: tcs, cache: promo)
        end
        execute_tool(resolver, "resolve", {
          "actor_id"   => rc["actor_id"] || player.id,
          "stat"       => rc["stat"] || "charisma",
          "action"     => rc["action"],
          "target_id"  => target_id,
          "difficulty" => rc["difficulty"],
          "time_minutes" => rc["time_minutes"] || 5
        }, into: tcs)
      end

      # Stage each NPC line for NARRATION without PERSISTING it. Committing every
      # "she slams her mug" as a durable event is what fills a thin NPC's soul
      # with atmosphere and feeds it back as her "knowledge" next turn (the Gerd
      # death-spiral). Raw dialogue is ephemeral now: intra-scene memory comes
      # from exchange_so_far; durable memory comes ONLY from commit_memorable (+
      # resolve / ignorance / claims, which are consequential by nature). The
      # staged record keeps the propose_event shape narration already reads, but
      # writes no Event row. Extra-promotion still persists (a new NPC appearing
      # IS consequential).
      def stage_dialogue(resolver, context, scene, events, player, promo, tcs)
        Array(events).each do |de|
          next unless de.is_a?(Hash) && de["prose"].to_s.strip != ""
          actor_id = de["actor_id"]
          if actor_id.nil? && de["extra_index"].is_a?(Integer)
            actor_id = promote_extra(resolver, context, scene, de["extra_index"], de["subrole"], into: tcs, cache: promo)
          end
          next unless actor_id
          args = {
            "scope"        => "local",
            "participants" => [
              { "character_id" => actor_id,  "role" => "actor" },
              { "character_id" => player.id, "role" => "participant" }
            ],
            "trigger"      => de["summary"].to_s[0, 60].presence || "exchange",
            "details"      => de["prose"],
            "time_minutes" => 5
          }
          tcs << tool_call("propose_event", args, { "staged" => true, "summary" => "[dialogue — rendered, not persisted]" })
        end
      end

      # Persist the ONE durable event a turn can earn — ONLY when the model flags
      # the exchange as consequential (a threat meant, a deal struck, a fact
      # revealed, a bond shifted). The conservative default: commit nothing
      # unless it mattered. resolve / ignorance / claims have their own paths;
      # this catches the consequential dialogue that isn't one of those.
      def commit_memorable(resolver, memorable, player, present, tcs)
        return unless memorable.is_a?(Hash)
        gist = memorable["gist"].to_s.strip
        return if gist.empty?
        participants = [ { "character_id" => player.id, "role" => "participant" } ]
        actor_id = memorable["actor_id"]
        if actor_id && present.any? { |c| c["id"] == actor_id }
          participants.unshift({ "character_id" => actor_id, "role" => "actor" })
        end
        execute_tool(resolver, "propose_event", {
          "scope"        => "local",
          "participants" => participants,
          "trigger"      => gist[0, 60],
          "details"      => gist,
          "time_minutes" => 5
        }, into: tcs)
      end

      # GROUND v0 — realize any named person the NPC introduced this turn into a
      # grounded row so it isn't a "Harek ghost" (a name in one line of dialogue
      # with no row behind it). This is the RESCUE half: it captures a name the
      # NPC already spoke; it does not encourage inventing more. The speaker is
      # the present NPC that named the person (claim.actor_id), defaulting to the
      # sole/first responder. Each realize is recorded as a `realize_claim`
      # tool_call so the orchestration is traceable in the turn log + play.log.
      # Failure is non-fatal — a missed claim degrades to the prior behaviour (a
      # prose-only ghost), never a broken turn.
      def commit_claims(context, claims, present, tcs)
        Array(claims).each do |c|
          next unless c.is_a?(Hash) && c["name"].to_s.strip != ""
          speaker = claim_speaker(c["actor_id"], present)
          res = ::Harness::NarrativeShift::Realizer.run(claim: c, speaker: speaker, context: context, logger: @logger)
          tcs << tool_call("realize_claim", c, res || { "error" => "claim realize returned nil" })
        end
      end

      # The present NPC credited with the claim. Falls back to the first present
      # character when actor_id is missing or not in the scene (common one-on-one
      # case: there's only one NPC anyway).
      def claim_speaker(actor_id, present)
        match = present.find { |c| c["id"] == actor_id } if actor_id
        row = match || present.first
        row && ::Npc.find_by(id: row["id"])
      end

      def commit_ignorance(resolver, entries, player, present, tcs)
        Array(entries).each do |ig|
          next unless ig.is_a?(Hash) && ig["actor_id"] && ig["topic"].to_s.strip != ""
          who = present.find { |c| c["id"] == ig["actor_id"] }&.dig("name") || "The NPC"
          execute_tool(resolver, "propose_event", {
            "scope"        => "personal",
            "participants" => [
              { "character_id" => ig["actor_id"], "role" => "actor" },
              { "character_id" => player.id,      "role" => "participant" }
            ],
            "trigger"      => "asserted ignorance",
            "details"      => "#{who} told the player they have not heard of #{ig['topic']}",
            "time_minutes" => 1
          }, into: tcs)
        end
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
