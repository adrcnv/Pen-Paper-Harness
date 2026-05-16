module Harness
  module Tools
    # Move an item from a character's inventory to their current
    # location. The item is then anchored to that location until
    # someone picks it up. Used when the player explicitly discards,
    # leaves something behind, or swaps out gear.
    class Drop < Base
      def self.tool_name
        "drop"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Move an item from a character's inventory to their current location. The actor (by_character_id) must own the item. The actor must have a location (not orphaned). On success, item.character_id = nil and item.location_id = actor.location_id. A personal-scope event is logged.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id"          => { "type" => "integer", "description" => "id of the item to drop" },
              "by_character_id"  => { "type" => "integer", "description" => "id of the character dropping (typically INPUT.player.id)" }
            },
            "required" => [ "item_id", "by_character_id" ]
          }
        }
      end

      def call(args, context)
        item_id = args["item_id"]
        char_id = args["by_character_id"]
        return { "error" => "item_id required" } if item_id.nil?
        return { "error" => "by_character_id required" } if char_id.nil?

        actor = ::Character.find_by(id: char_id)
        return { "error" => "no character with id=#{char_id}" } unless actor
        return { "error" => "actor id=#{char_id} has no location to drop into" } unless actor.location_id

        item = ::Item.find_by(id: item_id)
        return { "error" => "no item with id=#{item_id}" } unless item

        if item.character_id != actor.id
          return { "error" => "actor id=#{char_id} does not own item id=#{item_id} (owned by character_id=#{item.character_id || 'nobody'})" }
        end

        item.update!(character_id: nil, location_id: actor.location_id)
        log_event(actor, item, context)

        {
          "item_id"     => item.id,
          "item_name"   => item.name,
          "location_id" => actor.location_id
        }
      end

      private

      def log_event(actor, item, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  actor.location,
          details: {
            "drop" => {
              "actor_id"   => actor.id,
              "item_id"    => item.id,
              "item_name"  => item.name
            }
          },
          participants: [ { character: actor, role: "actor" } ]
        )
      end
    end
  end
end
