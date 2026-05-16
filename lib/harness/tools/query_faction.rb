module Harness
  module Tools
    class QueryFaction < Base
      def self.tool_name
        "query_faction"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Return a faction's core properties given its id. Factions include kingdoms (is_kingdom: true), guilds, cults, trade leagues, etc.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "faction_id" => { "type" => "integer", "description" => "id of the faction to query" }
            },
            "required" => [ "faction_id" ]
          }
        }
      end

      def call(args, _context)
        id = args["faction_id"]
        return { "error" => "faction_id required" } if id.nil?

        f = ::Faction.find_by(id: id)
        return { "error" => "no faction with id=#{id}" } unless f

        {
          "id"         => f.id,
          "name"       => f.name,
          "subrole"    => f.subrole,
          "is_kingdom" => f.is_kingdom,
          "properties" => f.properties || {}
        }
      end
    end
  end
end
