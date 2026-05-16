module Harness
  module Tools
    class QueryCharacter < Base
      def self.tool_name
        "query_character"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Return a character's core properties given its id. Works for NPCs AND the player (the player's id is in INPUT.player.id). Use the id from query_scene's present_characters.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "character_id" => { "type" => "integer", "description" => "id of the character to query (NPC or player)" }
            },
            "required" => [ "character_id" ]
          }
        }
      end

      def call(args, _context)
        id = args["character_id"]
        return { "error" => "character_id is required" } if id.nil?

        c = ::Character.find_by(id: id)
        return { "error" => "no character with id=#{id}" } unless c

        {
          "id"         => c.id,
          "name"       => c.name,
          "type"       => c.type,        # "Npc" or "Player"
          "subrole"    => c.subrole,
          "properties" => c.properties || {},
          "abilities"  => c.abilities    # nil = not materialized; [] = none; [...] = has these
        }
      end
    end
  end
end
