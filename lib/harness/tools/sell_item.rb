module Harness
  module Tools
    # Sell an owned item to a shop's merchant. The seller must be at a shop that
    # deals in the item's category (the smithy buys weapons/armor, not rings);
    # the merchant must be present and able to afford it. Price is the core's
    # sell price (Economy::Pricing — below buy price by the merchant's margin,
    # raised where the town lacks the good). The LLM never sets it.
    #
    # On success: merchant pays the seller, the item becomes shop stock
    # (anchored to the shop, for_sale) so it re-enters the economy. Atomic.
    class SellItem < Base
      def self.tool_name
        "sell_item"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Sell an item the seller owns to the merchant running the shop at the seller's location. The shop must deal in the item's category (a smithy buys weapons/armor, a market most gear). Price is fixed by the core (do NOT pass it) and is lower than buy price. Rejected if the merchant can't afford it. seller_id defaults to the player.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id"     => { "type" => "integer", "description" => "an item the seller owns" },
              "merchant_id" => { "type" => "integer", "description" => "the present character running the shop (pays the seller)" },
              "seller_id"   => { "type" => "integer", "description" => "defaults to the player if omitted" }
            },
            "required" => [ "item_id", "merchant_id" ]
          }
        }
      end

      def call(args, context)
        item_id     = args["item_id"]
        merchant_id = args["merchant_id"]
        seller_id   = args["seller_id"] || ::Player.first&.id

        return { "error" => "item_id required" }    if item_id.nil?
        return { "error" => "merchant_id required" } if merchant_id.nil?
        return { "error" => "seller_id required (no player row)" } if seller_id.nil?
        return { "error" => "seller and merchant must differ" } if seller_id == merchant_id

        seller   = ::Character.find_by(id: seller_id)
        return { "error" => "no character with id=#{seller_id}" } unless seller
        merchant = ::Character.find_by(id: merchant_id)
        return { "error" => "no character with id=#{merchant_id}" } unless merchant

        item = ::Item.find_by(id: item_id)
        return { "error" => "no item with id=#{item_id}" } unless item
        return { "error" => "seller id=#{seller_id} does not own item id=#{item_id}" } unless item.character_id == seller.id

        shop = merchant.location
        return { "error" => "merchant id=#{merchant_id} is not at a location" } unless shop
        return { "error" => "seller id=#{seller_id} is not with the merchant" } unless seller.location_id == shop.id

        # A shop buys what it stocks, through whoever sells here (staff, or the
        # venue's trade); a person buys what their own trade deals in besides
        # (Items::Offers — the same map that lays their table). Nobody with a
        # trade → nobody to sell to. Items run 8 t22: the market square's stall
        # list (weapons/armor/jewelry) stood in for the fishmonger's own trade
        # and he could not buy back a fish.
        stocked    = shop.properties.is_a?(Hash) ? Array(shop.properties["shop"]) : []
        categories = ::Harness::Items::Offers.categories_for(merchant, shop)
        categories = (categories + stocked).uniq if sells_here?(merchant, shop)
        return { "error" => "#{merchant.name} doesn't buy such things" } if categories.empty?
        unless deals_in?(categories, item)
          return { "error" => "#{merchant.name} doesn't deal in that (buys: #{categories.join('/')})" }
        end

        facts = ::Harness::Settlement::Facts.for(shop)
        price = ::Harness::Economy::Pricing.sell_price(item, wealth: facts["wealth"], economic_basis: facts["economic_basis"])

        if merchant.coins.to_i < price
          return { "error" => "merchant id=#{merchant_id} has only #{merchant.coins.to_i} coins; can't pay #{price} for #{item.name}" }
        end

        ::ActiveRecord::Base.transaction do
          merchant.update!(coins: merchant.coins - price)
          seller.update!(coins: seller.coins + price)
          props = item.properties.dup
          props["for_sale"]  = true
          props["seller_id"] = merchant.id   # it re-enters the economy on the buyer's table, under their name
          item.update!(character_id: nil, location_id: shop.id, properties: props)
        end

        log_event(seller, merchant, item, price, context)

        {
          "item_id"        => item.id,
          "item_name"      => item.name,
          "seller_id"      => seller.id,
          "merchant_id"    => merchant.id,
          "price"          => price,
          "seller_balance" => seller.coins
        }
      end

      private

      def sells_here?(merchant, shop)
        return true if merchant.respond_to?(:home_location_id) && merchant.home_location_id == shop.id
        trade = shop.properties.is_a?(Hash) ? shop.properties["trade"].to_s : ""
        !trade.empty? && merchant.subrole.to_s.downcase.include?(trade.downcase)
      end

      def deals_in?(categories, item)
        tags = Array(item.properties.is_a?(Hash) ? item.properties["tags"] : nil)
        # category keys map to a tag: weapons→weapon, armor→armor, jewelry→jewelry,
        # goods→goods (the tag keeps its s)
        wanted = categories.flat_map { |c| [ c.to_s, c.to_s.sub(/s\z/, "") ] }
        (wanted & tags).any?
      end

      def log_event(seller, merchant, item, price, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  merchant.location,
          details: {
            "summary"   => "#{seller.name} sold #{item.name} to #{merchant.name} for #{price} coins",
            "sell_item" => {
              "seller_id" => seller.id, "merchant_id" => merchant.id,
              "item_id" => item.id, "item_name" => item.name, "price" => price
            }
          },
          participants: [
            { character: seller,   role: "seller" },
            { character: merchant, role: "buyer" }
          ]
        )
      end
    end
  end
end
