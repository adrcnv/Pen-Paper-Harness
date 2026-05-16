module Harness
  module Combat
    module Tools
      # Combat-only. The current combatant explicitly closes their slot for
      # this round, even if they haven't spent both tokens. Used when an
      # NPC decides to wait, or when the player has nothing left to do.
      # The round driver auto-closes when (acted AND moved); end_turn is
      # the manual escape hatch.
      class EndTurn < ::Harness::Tools::Base
        def self.tool_name
          "end_turn"
        end

        def self.schema
          {
            "name"        => tool_name,
            "description" => "Combat-only. End your slot for this round even if you haven't used both action and move. Use when you're holding ground, conserving resources, or have nothing useful to do this round.",
            "input_schema" => {
              "type"       => "object",
              "properties" => {
                "actor_id" => { "type" => "integer", "description" => "the ending combatant's id; must be the current initiative slot" }
              },
              "required" => [ "actor_id" ]
            }
          }
        end

        def call(args, context)
          scene = context.active_scene
          return { "error" => "no active scene" } unless scene
          return { "error" => "not in combat" } unless scene.in_combat?

          state    = scene.combat
          actor_id = args["actor_id"].to_i
          return { "error" => "actor_id #{actor_id} is not a combatant" } unless state.combatant?(actor_id)
          return { "error" => "it is not actor_id=#{actor_id}'s turn (current actor is #{state.current_actor_id})" } unless state.current_actor_id == actor_id

          state.mark_acted!(actor_id)
          state.mark_moved!(actor_id)

          result = { "ok" => true, "actor_id" => actor_id, "slot_complete" => true }

          actor = ::Character.find_by(id: actor_id)
          state.record_action!(
            "tool"       => "end_turn",
            "actor_id"   => actor_id,
            "actor_name" => actor&.name,
            "args"       => args,
            "result"     => result
          )

          result
        end
      end
    end
  end
end
