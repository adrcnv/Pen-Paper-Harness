require "json"

module Harness
  module Scene
    # Character-initiative consumer (v4 — full capability). The world's answer
    # to the initiative gap: NPCs never volunteer engagement, so the SYSTEM
    # decides — each turn, AFTER narration — whether ONE present NPC seizes
    # the moment.
    #
    # v4 split (2026-07-24, user ruling: "the annoyance was never the same
    # person firing twice — it was an unensouled goober forced into a cheesy
    # one-liner"): the LLM pass here is a SELECTOR only — {actor, cause}, no
    # prose. The chosen NPC is then voiced through the conversation runner's
    # full machinery (Runners::Conversation#voice_unprompted): personality,
    # recall, live mood/agenda, repeat guard, memorable, reflection,
    # taking-stock. The beat is a first-class speaking turn, not improv from
    # a one-line agenda.
    #
    # Exclusion laws KILLED with it: no last-initiator rotation (it
    # permanently muted the sole NPC of a one-on-one), no engaged
    # de-prioritization (a grounded second turn is continuation, not a
    # glitch). ONE mechanical guard remains: an NPC who already voiced a
    # staged line THIS turn doesn't fire — that's the literal two-turns-in-
    # one-beat case with no fictional reading. The selector's "nobody is the
    # common answer" framing is the only throttle.
    class Initiative
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/scene_initiative.txt")
      MAX_PRESENT = 8

      # Returns the actor Npc who took a beat, plus the beat prose, or nil.
      #   { npc:, beat: }  |  nil
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
          return skip("no eligible candidates (present=#{@active.present_characters.size})")
        end

        with_agenda = candidates.count { |c| !@active.agenda_for(c.id).to_s.strip.empty? }
        @logger.info { "[Scene::Initiative] selecting over #{candidates.size} candidate(s), #{with_agenda} with agenda: #{candidates.map(&:name).join(', ')}" }

        spec = decide(candidates, player)
        return skip("selector returned nothing (parse fail or empty)") unless spec

        actor_name = spec["actor"].to_s.strip
        if actor_name.empty? || actor_name.casecmp?("null")
          return skip("selector chose nobody")
        end

        npc = candidates.find { |c| c.name == actor_name }
        return skip("selector named a non-candidate: #{actor_name.inspect}") unless npc

        cause = spec["cause"].to_s.strip
        cause = "acts on their own impulse" if cause.empty?

        # Full-capability voicing: recall, personality, mood ladder, repeat
        # guard, memorable — and reflection + taking-stock ride along, so an
        # initiative-struck deal or threat is canon-capable.
        prose = ::Harness::Runners::Conversation.new(logger: @logger).voice_unprompted(
          context: @context, npc: npc, cause: cause, input: @transcript.input, transcript: @transcript
        )
        return skip("voicing declined for #{actor_name}") if prose.to_s.strip.empty?

        beat = name_led(prose, npc.name)
        @active.last_initiator = npc.id
        @logger.info { "[Scene::Initiative] #{npc.name} acts (#{cause[0, 80]})" }
        { npc: npc, beat: beat }
      rescue StandardError => e
        @logger.warn { "[Scene::Initiative] failed: #{e.class}: #{e.message}" }
        nil
      end

      # The beat is generated in a context that knows its actor, then appended
      # verbatim to a narration that may have just described someone ELSE — a
      # leading "She" picks up the wrong antecedent ("...Magnus grins.\n\nShe
      # steps forward" read as nobody-knows-who). If the opening clause doesn't
      # name the actor, lead with the name, stage-direction style.
      def name_led(beat, name)
        first = name.to_s.split(/\s+/).first.to_s
        return beat if first.empty? || beat[0, 60].downcase.include?(first.downcase)
        "#{name} — #{beat}"
      end

      # Log why the pass produced no beat this turn, then return nil. Every
      # silent exit becomes one greppable INFO line — so a zero-fire session
      # shows WHERE it stopped (settle / no candidates / selector-nobody /
      # voicing-declined) rather than logging nothing at all.
      def skip(reason)
        @logger.info { "[Scene::Initiative] no beat — #{reason}" }
        nil
      end

      private

      # Present non-player NPCs, excluding followers and the ONE remaining
      # exclusion: characters who already voiced a staged line this turn (one
      # turn per character per turn). No rotation, no engaged-set carve-outs —
      # anyone else is fair game every turn; the selector's nobody-default is
      # the throttle.
      def eligible(player)
        spoke = spoke_this_turn
        @active.present_characters.reject do |c|
          c.id == player.id || follower?(c) || spoke.include?(c.id)
        end
      end

      # Actor ids of staged dialogue lines already in this turn's record.
      def spoke_this_turn
        ids = []
        @transcript.tool_calls.each do |tc|
          next unless tc["name"] == "propose_event" && tc.dig("result", "staged")
          Array(tc.dig("args", "participants")).each do |p|
            ids << p["character_id"] if p["role"] == "actor"
          end
        end
        ids
      end

      # The SELECTOR call: who moves, and why — never what they say. Live
      # mood (disposition-laddered) and agenda ride for every candidate; the
      # taking-stock pass keeps them current, so the old spoken-strip rule
      # is gone here too.
      def decide(candidates, player)
        present = candidates.first(MAX_PRESENT).map do |c|
          props = c.properties.is_a?(::Hash) ? c.properties : {}
          disp  = @active.disposition_for(c.id)
          {
            "name"    => c.name,
            "subrole" => c.subrole,
            "lens"    => props["lens"],
            "mood"    => [ (disp unless disp == "neutral"), @active.state_for(c.id) ].compact.join(" — ").presence,
            "agenda"  => @active.agenda_for(c.id)
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
        @logger.debug { "[Scene::Initiative] raw selector output (#{raw.to_s.size} bytes): #{raw}" }
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Scene::Initiative] selector failed: #{e.class}: #{e.message}" }
        nil
      end

      def follower?(c)
        c.properties.is_a?(::Hash) && c.properties["following_player"] == true
      end

      def llm
        @context.llm_nuance || @context.llm_grunt
      end

      def parse_emit(raw)
        parsed = ::Harness::LLM::JsonResponse.parse(raw)
        parsed.is_a?(::Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
