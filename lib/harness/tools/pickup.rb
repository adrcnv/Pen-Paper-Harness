module Harness
  module Tools
    # Move an item from its current location into a character's
    # inventory. The actor must be at the same location as the item.
    # Use for picking up items off the floor, off a table, off a
    # corpse-shaped pile (dead NPCs drop their items to the location
    # via Items::Loot at kill time).
    #
    # Coins on a corpse don't drop as items; loot them via
    # `transfer_coins(from_id=corpse, to_id=actor, amount=N)`.
    class Pickup < Base
      def self.tool_name
        "pickup"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Move an item from its anchor location into a character's inventory. The actor (by_character_id) must be at the same location as the item. Item must currently be location-anchored (not already owned). On success, item.character_id = actor and item.location_id = nil. A personal-scope event is logged.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id"          => { "type" => "integer", "description" => "id of the item to pick up" },
              "by_character_id"  => { "type" => "integer", "description" => "id of the character doing the picking up (typically INPUT.player.id)" }
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

        item = ::Item.find_by(id: item_id)
        return { "error" => "no item with id=#{item_id}" } unless item

        if item.character_id
          return { "error" => "item id=#{item_id} is already owned by character_id=#{item.character_id}; use give_item to transfer between characters" }
        end
        if item.location_id != actor.location_id
          return { "error" => "item id=#{item_id} is at location_id=#{item.location_id}; actor id=#{char_id} is at location_id=#{actor.location_id}; cannot pick up across locations" }
        end

        item.update!(character_id: actor.id, location_id: nil)
        log_event(actor, item, context)

        {
          "item_id"     => item.id,
          "item_name"   => item.name,
          "owner_id"    => actor.id,
          "owner_name"  => actor.name
        }
      end

      private

      def log_event(actor, item, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  actor.location,
          details: {
            "pickup" => {
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
