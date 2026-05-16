module Harness
  module Tools
    class QueryItem < Base
      def self.tool_name
        "query_item"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Return an item's core properties given its id. Items are either anchored to a location (location_id set) or held by a character (character_id set) — never both.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id" => { "type" => "integer", "description" => "id of the item to query" }
            },
            "required" => [ "item_id" ]
          }
        }
      end

      def call(args, _context)
        id = args["item_id"]
        return { "error" => "item_id required" } if id.nil?

        i = ::Item.find_by(id: id)
        return { "error" => "no item with id=#{id}" } unless i

        {
          "id"           => i.id,
          "name"         => i.name,
          "subrole"      => i.subrole,
          "location_id"  => i.location_id,
          "character_id" => i.character_id,
          "properties"   => i.properties || {}
        }
      end
    end
  end
end
