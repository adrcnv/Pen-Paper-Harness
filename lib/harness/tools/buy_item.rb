module Harness
  module Tools
    # Buy a for-sale ware from a shop. The item must be anchored to the buyer's
    # current location and flagged for_sale (shop stock); the merchant must be a
    # character present there to take payment. Price is computed mechanically
    # from the item's worth + the settlement's wealth + supply/demand by basis
    # (Economy::Pricing) — the LLM never sets it.
    #
    # On success: buyer pays the merchant (coins), item ownership flips to the
    # buyer, the for_sale flag is cleared. Atomic. One personal-scope event.
    class BuyItem < Base
      def self.tool_name
        "buy_item"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Buy a for-sale ware (seen in query_scene present_items with for_sale=true and a price) from the merchant running the shop. The item must be on sale at the buyer's current location; the merchant must be a character present there. Price is fixed by the core (do NOT pass it). The buyer pays the merchant; ownership transfers to the buyer. Rejected if the buyer can't afford it. buyer_id defaults to the player.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id"     => { "type" => "integer", "description" => "the for-sale item to purchase" },
              "merchant_id" => { "type" => "integer", "description" => "the present character running the shop (receives payment)" },
              "buyer_id"    => { "type" => "integer", "description" => "defaults to the player if omitted" }
            },
            "required" => [ "item_id", "merchant_id" ]
          }
        }
      end

      def call(args, context)
        item_id     = args["item_id"]
        merchant_id = args["merchant_id"]
        buyer_id    = args["buyer_id"] || ::Player.first&.id

        return { "error" => "item_id required" }     if item_id.nil?
        return { "error" => "merchant_id required" }  if merchant_id.nil?
        return { "error" => "buyer_id required (no player row)" } if buyer_id.nil?
        return { "error" => "buyer and merchant must differ" } if buyer_id == merchant_id

        buyer    = ::Character.find_by(id: buyer_id)
        return { "error" => "no character with id=#{buyer_id}" } unless buyer
        merchant = ::Character.find_by(id: merchant_id)
        return { "error" => "no character with id=#{merchant_id}" } unless merchant

        item = ::Item.find_by(id: item_id)
        return { "error" => "no item with id=#{item_id}" } unless item
        unless item.properties.is_a?(Hash) && item.properties["for_sale"]
          return { "error" => "item id=#{item_id} is not for sale" }
        end

        shop_loc = item.location_id
        return { "error" => "item id=#{item_id} is not anchored to a shop (owned, not stock)" } if shop_loc.nil?
        return { "error" => "buyer id=#{buyer_id} is not at the shop (loc=#{buyer.location_id}, item at #{shop_loc})" } unless buyer.location_id == shop_loc
        return { "error" => "merchant id=#{merchant_id} is not at the shop" } unless merchant.location_id == shop_loc

        facts = ::Harness::Settlement::Facts.for(item.location)
        price = ::Harness::Economy::Pricing.buy_price(item, wealth: facts["wealth"], economic_basis: facts["economic_basis"])

        if buyer.coins.to_i < price
          return { "error" => "buyer id=#{buyer_id} has #{buyer.coins.to_i} coins; #{item.name} costs #{price}" }
        end

        ::ActiveRecord::Base.transaction do
          buyer.update!(coins: buyer.coins - price)
          merchant.update!(coins: merchant.coins + price)
          props = item.properties.dup
          props.delete("for_sale")
          item.update!(location_id: nil, character_id: buyer.id, properties: props)
        end

        log_event(buyer, merchant, item, price, context)

        {
          "item_id"      => item.id,
          "item_name"    => item.name,
          "buyer_id"     => buyer.id,
          "merchant_id"  => merchant.id,
          "price"        => price,
          "buyer_balance" => buyer.coins
        }
      end

      private

      def log_event(buyer, merchant, item, price, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  buyer.location || merchant.location,
          details: {
            "buy_item" => {
              "buyer_id" => buyer.id, "merchant_id" => merchant.id,
              "item_id" => item.id, "item_name" => item.name, "price" => price
            }
          },
          participants: [
            { character: buyer,    role: "buyer" },
            { character: merchant, role: "seller" }
          ]
        )
      end
    end
  end
end
