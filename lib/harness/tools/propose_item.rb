module Harness
  module Tools
    # Instantiate a new Item at runtime. Used for items that the narrative
    # introduces and that need to persist across scenes — the letter on the
    # desk, the gem on the corpse, the brooch the courier delivered. Pure
    # scene flavor (chairs, mugs, the bar counter) stays as props and does
    # NOT come through here.
    #
    # Exactly one of `location_id` or `character_id` must be set:
    #   - location_id: anchored in the world (the sword in the rock)
    #   - character_id: in someone's inventory
    class ProposeItem < Base
      def self.tool_name
        "propose_item"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Create a new item, anchored to a location OR owned by a character (exactly one). Use for narratively-significant items that should persist across scenes — letters, gems, signature weapons. Don't use for scene flavor (chairs, mugs); those stay as prop description and evaporate at scene transition. `connection` grounds the item in existing state. Logs a personal-scope introduction event; if owned, the holder is a participant; if anchored, no participant.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "name"         => { "type" => "string", "description" => "item's display name" },
              "subrole"      => { "type" => "string", "description" => "archetype: weapon, document, drinkware, currency, ..." },
              "connection"   => { "type" => "string", "description" => "free-text rationale linking to existing state" },
              "location_id"  => { "type" => "integer", "description" => "anchor the item at this location (mutually exclusive with character_id)" },
              "character_id" => { "type" => "integer", "description" => "place the item in this character's inventory (mutually exclusive with location_id)" },
              "properties"   => { "type" => "object", "description" => "optional initial properties (condition, roll_modifier, sealed, ...)" }
            },
            "required" => [ "name", "subrole", "connection" ]
          }
        }
      end

      def call(args, context)
        name         = args["name"]
        subrole      = args["subrole"]
        connection   = args["connection"]
        location_id  = args["location_id"]
        character_id = args["character_id"]
        properties   = args["properties"] || {}

        return { "error" => "name must be a non-empty string" } unless name.is_a?(String) && !name.strip.empty?
        return { "error" => "subrole must be a non-empty string" } unless subrole.is_a?(String) && !subrole.strip.empty?
        return { "error" => "connection must be a non-empty string" } unless connection.is_a?(String) && !connection.strip.empty?
        return { "error" => "properties must be an object" } unless properties.is_a?(Hash)

        if location_id.nil? && character_id.nil?
          return { "error" => "exactly one of location_id or character_id required (anchored or owned)" }
        end
        if location_id && character_id
          return { "error" => "exactly one of location_id or character_id allowed, not both" }
        end

        location = nil
        character = nil
        if location_id
          location = ::Location.find_by(id: location_id)
          return { "error" => "no location with id=#{location_id}" } unless location
        else
          character = ::Character.find_by(id: character_id)
          return { "error" => "no character with id=#{character_id}" } unless character
        end

        item = ::Item.create!(
          name:       name,
          subrole:    subrole,
          location:   location,
          character:  character,
          properties: properties
        )

        event_location = character ? character.location : location
        participants   = character ? [ { character: character, role: "holder" } ] : []

        event = ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  event_location,
          details: {
            "introduction" => {
              "target_type"  => "item",
              "target_id"    => item.id,
              "target_name"  => item.name,
              "subrole"      => item.subrole,
              "anchored_at"  => location&.id,
              "owned_by"     => character&.id,
              "connection"   => connection
            },
            # Surfaced via Event.queryable for NPC speech sourcing — see
            # propose_character for the rationale.
            "narrative" => {
              "trigger" => "introduced #{item.subrole}",
              "details" => connection
            }
          },
          participants: participants
        )

        anchor_desc = item.character_id ? "in character_id=#{item.character_id}" : "at location_id=#{item.location_id}"
        {
          "item_id"           => item.id,
          "name"              => item.name,
          "subrole"           => item.subrole,
          "location_id"       => item.location_id,
          "character_id"      => item.character_id,
          "event_id"          => event.id,
          "game_time"         => context.game_time,
          "committed_summary" => "[committed item_id=#{item.id}] #{item.name} (#{item.subrole}) #{anchor_desc}"
        }
      end
    end
  end
end
