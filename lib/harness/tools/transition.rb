module Harness
  module Tools
    # Intra-location movement: parent ↔ child ↔ sibling. Cheap and instant
    # (1 minute). For inter-city movement (any top-level location with
    # coordinates → any other) use the `travel` tool — that flow handles
    # cursor advance, encounters, and arrival.
    class Transition < Base
      def self.tool_name
        "transition"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Move within the current containing location: to a sibling sublocation (other rooms under the same parent), to the parent location, or to a child sublocation (places INSIDE this one). Costs 1 minute and marks the scene for rebuild. For inter-city travel between top-level locations use the `travel` tool instead. ALWAYS use an id surfaced by query_scene.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "destination_id" => { "type" => "integer" }
            },
            "required" => [ "destination_id" ]
          }
        }
      end

      MOVE_COST = 1

      def call(args, context)
        id = args["destination_id"]
        return { "error" => "destination_id required" } if id.nil?

        dest = ::Location.find_by(id: id)
        return { "error" => "no location with id=#{id}" } unless dest

        unless sibling_or_parent_or_child?(context.player_location, dest)
          return { "error" => "destination=#{dest.name} is not reachable from #{context.player_location.name} via transition (use `travel` for inter-city movement)" }
        end

        from = context.player_location
        followers = followers_at(from)

        ::Harness::Clock.advance(context, minutes: MOVE_COST, reason: "transition(#{dest.name})")
        context.player_location = dest
        context.scene_dirty = true

        if (player = ::Player.first)
          player.update!(location_id: dest.id) unless player.location_id == dest.id
        end

        followers.each { |npc| npc.update!(location_id: dest.id) }

        result = {
          "moved_to"  => { "id" => dest.id, "name" => dest.name },
          "game_time" => context.game_time,
          "cost"      => MOVE_COST
        }
        result["followers_relocated"] = followers.map { |c| { "id" => c.id, "name" => c.name } } if followers.any?
        result
      end

      private

      def sibling_or_parent_or_child?(from, to)
        return true if from.parent_id && from.parent_id == to.parent_id
        return true if from.parent_id == to.id || to.parent_id == from.id
        false
      end

      # NPCs at the player's origin location whose properties carry
      # `following_player: true`. Filtered in Ruby because JSON1 boolean
      # coercion in SQLite is fragile; the candidate pool is at most a
      # handful per scene so the cost is negligible. The flag is set by
      # the LLM via mutate_character at recruitment and cleared on
      # dismissal — see the FOLLOWERS section in the reasoning prompt.
      def followers_at(loc)
        ::Npc.where(location_id: loc.id).select { |c|
          c.properties.is_a?(Hash) && c.properties["following_player"] == true
        }
      end
    end
  end
end
