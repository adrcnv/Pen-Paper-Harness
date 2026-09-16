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

        # A ware on the table (an offer, or shop stock) taken without paying,
        # with its seller or the venue's keeper standing there, is theft: the
        # thing still moves — the player really took it — and the wronged
        # party is owed its price, turns hostile, and remembers (items
        # overhaul 2026-09-15: robbery is the offer path run backwards).
        props   = item.properties.is_a?(Hash) ? item.properties : {}
        wronged = props["for_sale"] ? wronged_party(item, actor) : nil
        price   = wronged ? ::Harness::Tools::QueryScene.shop_price(item, item.location) : nil

        clean = props.dup
        clean.delete("for_sale")
        clean.delete("seller_id")
        item.update!(character_id: actor.id, location_id: nil, properties: clean)
        theft = wronged ? mark_theft!(actor, wronged, item, price, context) : nil
        log_event(actor, item, context, wronged, price)

        result = {
          "item_id"     => item.id,
          "item_name"   => item.name,
          "owner_id"    => actor.id,
          "owner_name"  => actor.name
        }
        result.merge!("stolen_from" => wronged.name, "stolen_from_id" => wronged.id, "price" => price, "obligation_id" => theft.id) if theft
        result
      end

      private

      # Who is wronged when a for-sale ware is taken: the character who put it
      # on the table, if they are here; else the venue's staff at their post.
      # Nobody present → an unwatched table, a plain pickup.
      def wronged_party(item, actor)
        return nil unless actor.is_a?(::Player)
        loc_id = item.location_id
        props  = item.properties.is_a?(Hash) ? item.properties : {}
        seller = ::Character.find_by(id: props["seller_id"]) if props["seller_id"]
        return seller if seller && seller.location_id == loc_id && seller.id != actor.id
        ::Npc.where(location_id: loc_id, home_location_id: loc_id).where.not(id: actor.id).first
      end

      def mark_theft!(actor, wronged, item, price, context)
        ob = ::Obligation.create!(
          debtor: actor, creditor: wronged, kind: "coins", amount: price,
          terms: "took #{item.name} from #{wronged.name}'s table without paying",
          status: "open", game_time: context.game_time.to_i, location_id: actor.location_id
        )
        if (active = context.active_scene)
          active.set_disposition!(wronged.id, "hostile")
          active.update_state!(wronged.id, "robbed in plain sight by #{actor.name}")
        end
        ob
      end

      def log_event(actor, item, context, wronged = nil, price = nil)
        details = {
          "pickup" => {
            "actor_id"   => actor.id,
            "item_id"    => item.id,
            "item_name"  => item.name
          }
        }
        participants = [ { character: actor, role: "actor" } ]
        if wronged
          # The summary is what a voice reads back from memory; a plain pickup
          # stays a bookkeeping row nobody recites.
          details["summary"] = "#{actor.name} took #{item.name} from #{wronged.name}'s table without paying (#{price} coins)"
          details["pickup"]["stolen_from_id"] = wronged.id
          participants << { character: wronged, role: "wronged" }
        end
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  actor.location,
          details:   details,
          participants: participants
        )
      end
    end
  end
end
