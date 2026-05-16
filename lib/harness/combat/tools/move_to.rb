module Harness
  module Combat
    module Tools
      # Spend the current combatant's MOVE token to change position bucket.
      # Three buckets only (engaged / near / far); the design's KISS rule.
      #
      # Movement rules:
      # - to "engaged": target_id REQUIRED. Creates a symmetric engagement
      #   edge between actor and target. Both end up at "engaged".
      # - to "near": from far (closing) or from engaged (disengaging — the
      #   engagement edge clears). target_id ignored.
      # - to "far": from near or engaged (disengaging). target_id ignored.
      #
      # The actor MUST be the current initiative slot (defense in depth —
      # the round driver should only let the right actor's slot dispatch).
      # The actor MUST NOT have spent move this round already.
      class MoveTo < ::Harness::Tools::Base
        VALID_POSITIONS = %w[engaged near far].freeze

        def self.tool_name
          "move_to"
        end

        def self.schema
          {
            "name"        => tool_name,
            "description" => "Combat-only. Spend your move token to change position bucket. Three buckets: engaged (in melee with a specific opponent), near (in the scene, not in melee), far (at range). Moving TO engaged requires target_id — you commit to a specific opponent. Moving away from engaged auto-disengages. One move per round.",
            "input_schema" => {
              "type"       => "object",
              "properties" => {
                "actor_id"  => { "type" => "integer", "description" => "the moving combatant's id; must be the current initiative slot" },
                "position"  => { "type" => "string", "enum" => VALID_POSITIONS, "description" => "destination bucket" },
                "target_id" => { "type" => "integer", "description" => "REQUIRED when position='engaged'; the opponent you're closing on. Ignored otherwise." }
              },
              "required" => [ "actor_id", "position" ]
            }
          }
        end

        def call(args, context)
          scene = context.active_scene
          return { "error" => "no active scene" } unless scene
          return { "error" => "not in combat" } unless scene.in_combat?

          state    = scene.combat
          actor_id = args["actor_id"].to_i
          position = args["position"]
          target_id = args["target_id"]&.to_i

          return { "error" => "actor_id #{actor_id} is not a combatant" } unless state.combatant?(actor_id)
          return { "error" => "it is not actor_id=#{actor_id}'s turn (current actor is #{state.current_actor_id})" } unless state.current_actor_id == actor_id
          return { "error" => "actor_id=#{actor_id} has already moved this round" } if state.moved?(actor_id)
          return { "error" => "position must be one of #{VALID_POSITIONS.inspect}" } unless VALID_POSITIONS.include?(position)

          if position == "engaged"
            return { "error" => "moving to engaged requires target_id" } if target_id.nil?
            return { "error" => "target_id #{target_id} is not a combatant" } unless state.combatant?(target_id)
            return { "error" => "cannot engage yourself" } if target_id == actor_id
          end

          previous_position = state.position_of(actor_id)
          previous_engaged  = state.engaged_with_of(actor_id)

          if position == "engaged"
            state.disengage!(actor_id) if previous_engaged && previous_engaged != target_id
            state.engage!(actor_id, target_id)
          else
            state.disengage!(actor_id) if previous_position == "engaged"
            state.set_position!(actor_id, position)
          end

          state.mark_moved!(actor_id)

          result = {
            "ok"            => true,
            "actor_id"      => actor_id,
            "from_position" => previous_position,
            "to_position"   => state.position_of(actor_id),
            "engaged_with"  => state.engaged_with_of(actor_id),
            "moved_this_round" => true,
            "slot_complete" => state.slot_complete?(actor_id)
          }

          actor = ::Character.find_by(id: actor_id)
          state.record_action!(
            "tool"       => "move_to",
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
