module Harness
  module Tools
    # Returns a character's items + coin balance. Use to see what
    # someone is carrying — the player checking their pack, the player
    # eyeing what an NPC has on them (subject to whether they could
    # plausibly know; query is structural, narration carries plausibility).
    class QueryInventory < Base
      def self.tool_name
        "query_inventory"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Return the items owned by a character (each as id, name, subrole, properties) plus their coin balance. Items in this list have character_id set; items at a location appear in query_scene's present_items instead. Use before pickup/drop/give_item to confirm what's available.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "character_id" => { "type" => "integer", "description" => "id of the character whose inventory to read" }
            },
            "required" => [ "character_id" ]
          }
        }
      end

      def call(args, _context)
        id = args["character_id"]
        return { "error" => "character_id required" } if id.nil?

        c = ::Character.find_by(id: id)
        return { "error" => "no character with id=#{id}" } unless c

        {
          "character_id" => c.id,
          "name"         => c.name,
          "coins"        => c.coins.to_i,
          "items"        => c.items.order(:id).map { |i|
            { "id" => i.id, "name" => i.name, "subrole" => i.subrole, "properties" => i.properties || {} }
          }
        }
      end
    end
  end
end
