module Harness
  module Tools
    # Explicit time advancement without an in-fiction action. Use this for
    # rests, waits, sleep, and idle lingers — anywhere the player wants the
    # clock to move without resolving / proposing / transitioning.
    #
    # Most action tools (resolve, propose_event, transition) advance time as
    # a side effect of their work. pass_time exists for the cases those don't
    # cover: "I sleep 8 hours at the inn", "I wait until dusk", "I sit
    # watching the door for an hour".
    #
    # A skip of >= IN_SCENE_THRESHOLD (60min) sets scene_dirty so the next turn
    # rebuilds the scene. This is explicit, player-chosen time passing — not the
    # silent conversation-accrual rebuild that caused scene whiplash (removed).
    # An 8-hour rest will rebuild the scene on the next turn (catch-up sim
    # gets a real gap to fill, internal-state regenerates, present
    # characters re-checked).
    class PassTime < Base
      VALID_INTENTS         = %w[rest wait sleep linger].freeze
      RESTORATIVE_INTENTS   = %w[rest sleep].freeze

      def self.tool_name
        "pass_time"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Advance the in-fiction clock without resolving an action. For rests, waits, sleeps, idle lingers — anything the player chooses to do that takes time but isn't a stat check, a narrative event worth recording, or a move. Crossing ~1 hour rebuilds the scene on the next turn (catch-up may surface new ambient color, internal states refresh). Do NOT use to skip narrative beats the LLM finds dull — pass_time should follow PLAYER intent (they said 'I rest', 'wait until evening', 'sit and watch').",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "intent"           => { "type" => "string", "enum" => VALID_INTENTS, "description" => "what kind of pass-time this is. Shapes narration tone but doesn't change clock math." },
              "duration_minutes" => { "type" => "integer", "description" => "how many in-fiction minutes pass. Sleep at an inn ~480 (8h). Wait until dusk varies. Linger at the bar ~60-180. Must be > 0." }
            },
            "required" => [ "intent", "duration_minutes" ]
          }
        }
      end

      def call(args, context)
        intent   = args["intent"]
        duration = args["duration_minutes"]

        return { "error" => "intent must be one of: #{VALID_INTENTS.join(', ')}" } unless VALID_INTENTS.include?(intent)
        return { "error" => "duration_minutes must be a positive integer" } unless duration.is_a?(Integer) && duration > 0

        before = context.game_time || 0
        ::Harness::Clock.advance(context, minutes: duration, reason: "pass_time(#{intent})")

        # Explicit, substantial time-skips rebuild the scene on the next turn
        # (catch-up surfaces what changed while the player idled; internal
        # states refresh). This is the ONLY accrual-style rebuild left, and it's
        # safe from the "scene whiplash" because the PLAYER chose to let time
        # pass — they expect the world to have moved. Short waits/lingers
        # (< IN_SCENE_THRESHOLD) don't rebuild, so a quick "wait a moment"
        # doesn't whiplash the scene.
        context.scene_dirty = true if duration >= ::Harness::Clock::IN_SCENE_THRESHOLD

        # Restorative intents (rest / sleep) refresh the player's ability
        # uses_remaining back to each library entry's uses_per_rest, AND
        # restore current_hp to max_hp. Wait / linger are non-restorative —
        # the clock moves but nothing recovers. NPCs do not refresh here;
        # they're handled by scene rebuild + the implicit "off-screen NPCs
        # have whatever they have when next we see them" rule.
        refreshed = false
        if RESTORATIVE_INTENTS.include?(intent)
          player = ::Player.first
          if player
            refresh_player_uses!(player)
            restore_player_hp!(player)
            refreshed = true
          end
        end

        {
          "intent"           => intent,
          "duration_minutes" => duration,
          "before"           => before,
          "after"            => context.game_time,
          "scene_dirty"      => context.scene_dirty,
          "refreshed"        => refreshed
        }
      end

      private

      def refresh_player_uses!(player)
        return unless Array(player.abilities).any?
        refreshed = player.abilities.map do |a|
          a.merge("uses_remaining" => a["uses_per_rest"])
        end
        player.update!(abilities: refreshed)
      end

      def restore_player_hp!(player)
        return if player.max_hp.to_i <= 0
        player.update!(current_hp: player.max_hp)
      end
    end
  end
end
