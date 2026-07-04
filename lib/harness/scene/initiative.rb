require "json"

module Harness
  module Scene
    # Character-initiative consumer (v3). The world's answer to the initiative
    # gap: NPCs never volunteer engagement, so the SYSTEM decides — each turn,
    # AFTER narration — whether ONE present NPC makes an unprompted move toward
    # the player, and renders it as its own beat.
    #
    # This is a DEDICATED consumer with a narrow reasoning surface (the thing
    # the old diffuse "voice a buried agenda string" pass lacked, which is why
    # it was never felt). It runs post-narration ON PURPOSE: it reads the turn's
    # actual narration prose, so the beat answers what just happened instead of
    # firing a stale scene-entry string. Its output is appended to the turn as
    # its own trailing paragraph — foregrounded, not woven into the main
    # narration where it used to get lost.
    #
    # Inputs: present characters (each with their seeded agenda toward the
    # player + internal_state + lens), the player's input, and the full turn
    # narration. Output: at most one actor's beat, or none. One LLM call.
    #
    # Pacing: fires every turn after a one-turn arrival-settle; the model's own
    # "nobody acts" option plus a light don't-repeat-last-actor rotation give
    # the "often but not always" feel. No combat escalation in this version —
    # a hostile-kind beat creates pressure as prose; it does not auto-start a
    # fight (deferred).
    class Initiative
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/scene_initiative.txt")
      MAX_PRESENT = 8

      # Returns the actor Npc who took a beat, plus the beat prose, or nil.
      #   { npc:, beat:, kind: }  |  nil
      def self.run(context:, active:, transcript:, narration:, logger: Rails.logger)
        new(context: context, active: active, transcript: transcript, narration: narration, logger: logger).run
      end

      def initialize(context:, active:, transcript:, narration:, logger: Rails.logger)
        @context    = context
        @active     = active
        @transcript = transcript
        @narration  = narration.to_s
        @logger     = logger
      end

      def run
        return skip("no active scene") unless @active
        return skip("in combat") if @active.in_combat?
        player = ::Player.first
        return skip("no player row") unless player

        # Arrival-settle: skip the turn the scene was entered, so nobody pipes
        # up the instant the player walks in. Armed here, fires every turn after.
        if @active.initiative_cooldown.nil?
          @active.initiative_cooldown = 0
          return skip("arrival-settle (armed; fires next turn)")
        end

        candidates = eligible(player)
        if candidates.empty?
          return skip("no eligible candidates (present=#{@active.present_characters.size}, last_initiator=#{@active.last_initiator.inspect})")
        end

        # Evidence: who's eligible and whether each carries an agenda. An
        # eligible set with no agendas is the "nothing to act on" condition.
        with_agenda = candidates.count { |c| !@active.agenda_for(c.id).to_s.strip.empty? }
        @logger.info { "[Scene::Initiative] deciding over #{candidates.size} candidate(s), #{with_agenda} with agenda: #{candidates.map(&:name).join(', ')}" }

        spec = decide(candidates, player)
        return skip("decide returned nothing (parse fail or empty)") unless spec

        actor_name = spec["actor"].to_s.strip
        if actor_name.empty? || actor_name.casecmp?("null")
          return skip("model chose nobody")
        end

        npc = candidates.find { |c| c.name == actor_name }
        return skip("model named a non-candidate: #{actor_name.inspect}") unless npc

        beat = spec["beat"].to_s.strip
        return skip("empty beat for #{actor_name}") if beat.empty?

        kind = spec["kind"].to_s.strip
        toward, label = resolve_target(spec["target"], npc, player)
        stage_beat(npc, player, beat, kind, toward, label)
        @active.last_initiator = npc.id
        @logger.info { "[Scene::Initiative] #{npc.name} acts (#{kind.empty? ? 'beat' : kind})" }
        { npc: npc, beat: beat, kind: kind }
      rescue StandardError => e
        @logger.warn { "[Scene::Initiative] failed: #{e.class}: #{e.message}" }
        nil
      end

      # Log why the pass produced no beat this turn, then return nil. Every
      # silent exit becomes one greppable INFO line — so a zero-fire session
      # shows WHERE it stopped (settle / no candidates / model-nobody / invalid)
      # rather than logging nothing at all.
      def skip(reason)
        @logger.info { "[Scene::Initiative] no beat — #{reason}" }
        nil
      end

      private

      # Present non-player NPCs eligible to take initiative, excluding the
      # player, followers, and the previous turn's initiator (light rotation).
      #
      # Engaged NPCs (the people the player interacted with THIS turn) are
      # only DE-PRIORITISED, not excluded: in a crowd we'd rather a different
      # NPC pipe up than pile a second beat on the one just spoken to, but in
      # a ONE-ON-ONE the engaged NPC is the only one present — excluding them
      # made initiative structurally impossible in a two-hander conversation
      # (playtest evidence: a 4-turn session fired zero beats, two turns of it
      # a 1-on-1 where the sole NPC was excluded right here). So: prefer the
      # not-engaged set, but fall back to the engaged one when it's all we have.
      def eligible(player)
        present = @active.present_characters.reject do |c|
          c.id == player.id || follower?(c) || c.id == @active.last_initiator
        end
        engaged = engaged_ids(player)
        not_engaged = present.reject { |c| engaged.include?(c.id) }
        not_engaged.any? ? not_engaged : present
      end

      # One structured-emit call: given who's present (+ angle/mood/lens), what
      # the player did, and the turn narration, pick ≤1 actor and their beat.
      def decide(candidates, player)
        present = candidates.first(MAX_PRESENT).map do |c|
          props = c.properties.is_a?(::Hash) ? c.properties : {}
          {
            "name"           => c.name,
            "subrole"        => c.subrole,
            "lens"           => props["lens"],
            "internal_state" => @active.state_for(c.id),
            "agenda"         => @active.agenda_for(c.id)
          }.compact
        end

        user = JSON.pretty_generate(
          "player_input" => @transcript.input,
          "player_name"  => player.name,
          "present"      => present,
          "narration"    => @narration
        )

        raw = ::Harness::CostTracker.in_subsystem(:scene_initiative_consumer) do
          llm.complete(system: preamble, user: "INPUT:\n#{user}")
        end
        @logger.debug { "[Scene::Initiative] raw decide output (#{raw.to_s.size} bytes): #{raw}" }
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Scene::Initiative] decide failed: #{e.class}: #{e.message}" }
        nil
      end

      # Record the NPC's unprompted move as a STAGED propose_event — it enters
      # the turn log (traceability) and its prose is appended to the narration
      # by the turn loop (via run's return value), but it writes NO Event row.
      #
      # Initiative beats are ephemeral atmosphere, exactly like raw dialogue:
      # persisting them as events let an NPC's improv ("the trees scream in the
      # Blackwood") self-canonize into the log and feed back next turn as that
      # NPC's "knowledge" — the same pollution conservative dialogue-committing
      # already fixed. So beats stage, never persist. (No double-render: the
      # turn loop appends the beat from the return value, not from this record.)
      # Hostile/engaging kinds still mark the player a target in the record; a
      # passive 'watch' marks them a witness.
      def stage_beat(npc, player, beat, kind, toward, label)
        role   = kind == "watch" ? "witness" : "target"
        prefix = label ? "#{npc.name} acts toward #{label}, unprompted" : "#{npc.name} acts, unprompted"
        args = {
          "scope"        => "personal",
          "participants" => [
            { "character_id" => npc.id,    "role" => "actor" },
            { "character_id" => toward.id, "role" => role }
          ],
          "trigger" => "unprompted initiative beat",
          "details" => "#{prefix} — #{beat}"
        }
        @transcript.record_tool_calls([
          { "name" => "propose_event", "args" => args,
            "result" => { "staged" => true, "summary" => "[initiative beat — rendered, not persisted]" } }
        ])
      end

      # Resolve the beat's `target` to [character, label]. Default + "player" +
      # "the room" → the player (label nil for "the room", so the record reads
      # "acts, unprompted" rather than falsely "toward the player"). A present
      # character name (not the actor) → that character, so an NPC→NPC beat is
      # recorded honestly. The target is traceability only — beats no longer
      # persist as events — so an unrecognised name degrades to the player.
      def resolve_target(target_name, actor, player)
        name = target_name.to_s.strip
        return [ player, "the player" ] if name.empty? || name.casecmp?("player")
        return [ player, nil ]          if name.casecmp?("the room")
        other = @active.present_characters.find { |c| c.name.casecmp?(name) && c.id != actor.id }
        other ? [ other, other.name ] : [ player, "the player" ]
      end

      def follower?(c)
        c.properties.is_a?(::Hash) && c.properties["following_player"] == true
      end

      # Character ids the player interacted with this turn (participants of any
      # committed event, or resolve targets/actors) — don't shove a beat in for
      # an NPC the scene already engaged.
      def engaged_ids(player)
        ids = []
        @transcript.tool_calls.each do |tc|
          parts = tc.dig("result", "participants")
          ids.concat(parts.map { |p| p["character_id"] }) if parts.is_a?(::Array)
          %w[target_id actor_id character_id].each do |k|
            v = tc.dig("result", k) || tc.dig("args", k)
            ids << v if v
          end
        end
        ids.compact.map(&:to_i).uniq.reject { |id| id == player.id }
      end

      def llm
        @context.llm_nuance || @context.llm_grunt
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end

      def parse_emit(raw)
        ::Harness::LLM::JsonResponse.parse(raw).then { |o| o.is_a?(::Hash) ? o : nil }
      rescue StandardError
        text = raw.to_s
        s = text.index("{"); e = text.rindex("}")
        return nil unless s && e && e > s
        begin
          JSON.parse(text[s..e])
        rescue StandardError
          nil
        end
      end
    end
  end
end
