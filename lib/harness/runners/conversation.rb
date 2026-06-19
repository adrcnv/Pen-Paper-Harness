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

        npcs = present.map { |c| npc_knowledge(resolver, c, tcs) }
        emit = converse(context, input, step, player, npcs, scene)
        return redispatch("conversation emit unparseable", tcs) unless emit

        commit_resolve(resolver, context, scene, emit["resolve_call"], player, promo, tcs)
        commit_dialogue(resolver, context, scene, emit["dialogue_events"], player, promo, tcs)
        commit_ignorance(resolver, emit["ignorance"], player, present, tcs)

        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      private

      # Prefetch what this NPC could plausibly know (Ruby/SQL, no LLM).
      def npc_knowledge(resolver, char, tcs)
        res, _ = execute_tool(resolver, "query_events", { "for_holder_id" => char["id"], "limit" => EVENT_SUMMARY_CAP }, into: tcs)
        events = Array(res.is_a?(Hash) ? res["events"] : res).map { |e|
          e.is_a?(Hash) ? (e["trigger"] || e["summary"] || e["details"]).to_s[0, 120] : e.to_s[0, 120]
        }.reject(&:empty?)
        {
          "id"      => char["id"],
          "name"    => char["name"],
          "subrole" => char["subrole"],
          "lens"    => char["lens"],
          "events"  => events
        }
      end

      def converse(context, input, step, player, npcs, scene)
        user = JSON.pretty_generate(
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

      def commit_dialogue(resolver, context, scene, events, player, promo, tcs)
        Array(events).each do |de|
          next unless de.is_a?(Hash) && de["prose"].to_s.strip != ""
          actor_id = de["actor_id"]
          if actor_id.nil? && de["extra_index"].is_a?(Integer)
            actor_id = promote_extra(resolver, context, scene, de["extra_index"], de["subrole"], into: tcs, cache: promo)
          end
          next unless actor_id
          execute_tool(resolver, "propose_event", {
            "scope"        => "local",
            "participants" => [
              { "character_id" => actor_id,  "role" => "actor" },
              { "character_id" => player.id, "role" => "participant" }
            ],
            "trigger"      => de["summary"].to_s[0, 60].presence || "exchange",
            "details"      => de["prose"],
            "time_minutes" => 5
          }, into: tcs)
        end
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
