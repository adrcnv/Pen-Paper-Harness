module Harness
  module Tools
    # Read-only: returns the active travel journey state, or { active: false }
    # when the player is not mid-trip. Use to know whether the player is
    # paused at an encounter / snap / origin and is mid-journey to somewhere
    # vs at a settled location.
    class QueryJourney < Base
      def self.tool_name
        "query_journey"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Return the active travel journey state. When `active: true`, the player is mid-journey — they're currently stopped at some location (encounter, snap, or origin) and have a pending destination. The cursor + remaining_distance describe how far they have left. To continue traveling, call `travel(destination_id)` with the same destination_id; to redirect or abandon, call travel with a different id (replaces the journey) or just stay where they are. When `active: false`, no journey is in progress; use the normal scene/transition flow.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {},
            "required"   => []
          }
        }
      end

      def call(_args, _context)
        journey = ::Journey.active
        return { "active" => false } unless journey

        {
          "active"               => true,
          "destination"          => { "id" => journey.destination_id, "name" => journey.destination.name },
          "origin"               => { "x" => journey.origin_x.round(2), "y" => journey.origin_y.round(2) },
          "cursor"               => { "x" => journey.cursor_x.round(2), "y" => journey.cursor_y.round(2) },
          "elapsed_minutes"      => journey.elapsed_minutes,
          "remaining_distance"   => journey.remaining_distance.round(2),
          "started_at_game_time" => journey.started_at_game_time,
          "cooldown_until_game_time" => journey.cooldown_until_game_time
        }
      end
    end
  end
end
