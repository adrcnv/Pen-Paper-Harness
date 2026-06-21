module Harness
  module Scene
    # Character-initiative pass (v2). The world's answer to the initiative gap:
    # NPCs sit in a local maximum and never act unprompted, so the SYSTEM gives
    # a present NPC a proactive beat on a cadence. Runs AFTER the player's runner
    # chain and BEFORE the combat hand-off — a post-chain system pass, NOT a
    # planner-emitted runner (initiative isn't player intent). It owns ALL the
    # timing; the old per-character silent-turn pressure was torn out so nothing
    # competes here.
    #
    # WHAT IT VOICES (the v1→v2 fix — v1 fired ~zero because it only ever voiced
    # the single rare PLAYER-TARGETED agenda, which the player usually engaged,
    # so it was always excluded):
    #   - if the chosen NPC has an AGENDA (rare, player-targeted goal/friction) →
    #     voice that. This is the strong hook, and the ONLY thing that can
    #     escalate.
    #   - else → voice their INTERNAL_STATE (every present NPC has one): ambient
    #     inner life surfaced as a small unprompted beat (a glance, a mutter, an
    #     aside). NOT player-targeted, so it never reads as "everyone is scheming
    #     at me" — it just makes the room feel inhabited. The player may bite or
    #     walk past; the world moved either way.
    #
    # ROTATION: prefer an un-voiced NPC each firing, so the scene's characters
    # each get a moment rather than one NPC repeating. Ambient beats fire once
    # per NPC per scene; agenda NPCs may be re-pushed (that's the escalation
    # ramp). When everyone eligible has been voiced, the pass goes quiet.
    #
    # ESCALATION (the "drunk finally swings") is gated on having a real AGENDA
    # (player-targeted) + a FIGHT-CAPABLE archetype + the 2nd ignored push. An
    # internal_state voicing can NEVER escalate — a barkeep grumbling about his
    # back will not draw steel on you, regardless of cadence. That, plus
    # fight-capability, is the structural tavern-keep guarantee.
    #
    # The beat is committed as a forward propose_event (NPC actor, player
    # participant); narration — which runs right after — renders it into prose.
    # No extra LLM call in the common path. Transport-agnostic: the same
    # committed beat is what a future web/push server pushes between turns.
    class Initiative
      # Quiet turns between beats — a beat lands roughly every CADENCE+1 turns.
      # Armed on the scene's first eligible turn so nobody pipes up the instant
      # the player walks in. Tunable.
      CADENCE = 2

      # Ignored agenda pushes before a fight-capable NPC escalates to combat.
      ESCALATE_AFTER = 2

      # Subroles whose archetype plausibly starts violence. Conservative — the
      # point is to EXCLUDE peaceful townsfolk, not enumerate every fighter.
      # role_intent (set on encounter hostiles) is the other fight-capable signal.
      MARTIAL_SUBROLES = %w[
        bandit brigand raider outlaw thug tough enforcer mercenary sellsword
        guard soldier watchman knight warrior hunter assassin cutthroat reaver
      ].freeze

      def self.run(context:, active:, transcript:, logger: Rails.logger)
        new(context: context, active: active, transcript: transcript, logger: logger).run
      end

      def initialize(context:, active:, transcript:, logger: Rails.logger)
        @context    = context
        @active     = active
        @transcript = transcript
        @logger     = logger
      end

      # Returns the NPC who took a beat, or nil if nothing fired.
      def run
        return nil unless @active
        player = ::Player.first
        return nil unless player

        pushes = (@active.initiative_pushes ||= Hash.new(0))

        # The player engaging an NPC this turn resets their pressure — the scene
        # moved on its own; no need to shove a beat in for them.
        engaged = engaged_ids(player)
        engaged.each { |id| pushes[id] = 0 }

        return nil unless cadence_ready?

        npc = pick_target(exclude: engaged, player: player, pushes: pushes)
        return nil unless npc

        agenda = @active.agenda_for(npc.id).to_s.strip
        count  = pushes[npc.id].to_i

        if !agenda.empty? && (count + 1) >= ESCALATE_AFTER && fight_capable?(npc)
          fire_escalation(npc, agenda, player)
          @logger.info { "[Scene::Initiative] #{npc.name} escalates a standing agenda to combat" }
        elsif !agenda.empty?
          fire_beat(npc, player, agenda, kind: :agenda)
          @logger.info { "[Scene::Initiative] #{npc.name} pushes their agenda (push ##{count + 1})" }
        else
          state = @active.state_for(npc.id).to_s.strip
          return nil if state.empty?
          fire_beat(npc, player, state, kind: :ambient)
          @logger.info { "[Scene::Initiative] #{npc.name} voices their preoccupation, unprompted" }
        end

        pushes[npc.id] = count + 1
        @active.initiative_cooldown = CADENCE
        npc
      rescue StandardError => e
        @logger.warn { "[Scene::Initiative] failed: #{e.class}: #{e.message}" }
        nil
      end

      private

      # Cadence gate. nil cooldown = scene's first eligible turn: arm it so the
      # first beat lands a few turns in, never on arrival. Decrements while
      # quiet; ready only at zero.
      def cadence_ready?
        cd = @active.initiative_cooldown
        cd = CADENCE if cd.nil?
        if cd > 0
          @active.initiative_cooldown = cd - 1
          return false
        end
        true
      end

      # Choose who pipes up. Priority, all over present non-follower NPCs the
      # player didn't engage this turn:
      #   1. a fresh (un-voiced) AGENDA holder — the strongest hook;
      #   2. a fresh ambient NPC — voice their inner life once;
      #   3. a previously-pushed AGENDA holder — re-push toward escalation.
      # Ambient NPCs are never re-voiced (no repeating the same mood); when
      # everyone's had a beat, the pass returns nil and the scene settles.
      def pick_target(exclude:, player:, pushes:)
        eligible = @active.present_characters.reject do |c|
          c.id == player.id || exclude.include?(c.id) || follower?(c)
        end
        return nil if eligible.empty?

        with_agenda, ambient = eligible.partition { |c| @active.agenda_for(c.id).to_s.strip != "" }

        with_agenda.find { |c| pushes[c.id].to_i.zero? } ||
          ambient.find { |c| pushes[c.id].to_i.zero? } ||
          with_agenda.find { |c| pushes[c.id].to_i.positive? }
      end

      # The structural escalation gate — the tavern-keep guarantee. True only for
      # NPCs whose archetype or seeded intent plausibly turns violent.
      def fight_capable?(c)
        props = c.properties
        return true if props.is_a?(Hash) && props["role_intent"].to_s.strip != ""
        sub = c.subrole.to_s.downcase
        MARTIAL_SUBROLES.any? { |m| sub.include?(m) }
      end

      def follower?(c)
        c.properties.is_a?(Hash) && c.properties["following_player"] == true
      end

      # Commit the NPC's unprompted move as a forward event. Narration renders
      # it; no LLM call here. Agenda beats are player-targeted; ambient beats are
      # a small surfaced preoccupation the narrator should render lightly (a
      # glance, an aside, a mutter) — the player witnesses, isn't cornered.
      def fire_beat(npc, player, text, kind:)
        detail, role =
          if kind == :agenda
            [ "#{npc.name} takes the initiative toward the player, unprompted — #{text}", "target" ]
          else
            [ "#{npc.name} lets a preoccupation surface, unprompted and in passing (a glance, an aside, a mutter) — #{text}", "witness" ]
          end

        commit("propose_event", {
          "scope"        => "personal",
          "participants" => [
            { "character_id" => npc.id,    "role" => "actor" },
            { "character_id" => player.id, "role" => role }
          ],
          "trigger" => "unprompted #{kind} beat",
          "details" => detail
        })
      end

      # Escalation: skip the separate beat (start_combat logs its own entry with
      # the inciting_beat) and enter combat. The turn loop's combat hand-off,
      # which runs right after this pass, drives it.
      def fire_escalation(npc, agenda, player)
        commit("start_combat", {
          "sides" => [
            { "name" => "player_party", "members" => [ player.id ] },
            { "name" => "hostiles",     "members" => [ npc.id ] }
          ],
          "inciting_beat" => "#{npc.name} forces a standing grievance to violence against the player — #{agenda}"
        })
      end

      def commit(name, args)
        resolver = ::Harness::Resolver.new(
          context: @context, tools: ::Harness::Resolver::DEFAULT_TOOLS, logger: @logger
        )
        call   = ::Harness::LLM::ToolCall.new(name: name, args: args)
        result = resolver.execute(call)
        @transcript.record_tool_calls([ { "name" => name, "args" => args, "result" => result } ])
        result
      end

      # Character ids the player interacted with this turn (participants of any
      # committed event, or resolve targets/actors). Used to reset pushed
      # pressure when the scene engaged the NPC on its own.
      def engaged_ids(player)
        ids = []
        @transcript.tool_calls.each do |tc|
          parts = tc.dig("result", "participants")
          ids.concat(parts.map { |p| p["character_id"] }) if parts.is_a?(Array)
          %w[target_id actor_id character_id].each do |k|
            v = tc.dig("result", k) || tc.dig("args", k)
            ids << v if v
          end
        end
        ids.compact.map(&:to_i).uniq.reject { |id| id == player.id }
      end
    end
  end
end
