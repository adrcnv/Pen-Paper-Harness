module Harness
  module Tools
    # A swap: one carried item of the trader's for wares on the table, no coin.
    # Table-first (items overhaul 2026-09-15): the wares exist as for-sale rows
    # with a seller, so the counterparty's side is real before the deal is
    # struck. The engine judges the swap by value — the trader's item at its
    # sell price against the wares at their asking prices — and accepts a fair
    # or generous one; the character's spoken "hands on it" is colour, the
    # pricing engine is the ruling. Atomic. One personal-scope event with a
    # summary both memories can read.
    class TradeItems < Base
      def self.tool_name
        "trade_items"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Swap one carried item, plus coins if any, for wares on the table (present_items with for_sale=true). The counterparty must be the wares' seller (or the venue's keeper). Accepted when the item's value plus the coins covers the wares' asking prices; refused otherwise. trader_id defaults to the player.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id"      => { "type" => "integer", "description" => "the carried item given up" },
              "for_item_ids" => { "type" => "array", "items" => { "type" => "integer" }, "description" => "the for-sale wares taken in return" },
              "with_id"      => { "type" => "integer", "description" => "the counterparty (the wares' seller)" },
              "coins"        => { "type" => "integer", "description" => "coins the trader adds on top of the item (default 0)" },
              "trader_id"    => { "type" => "integer", "description" => "who gives the item (defaults to the player)" }
            },
            "required" => [ "item_id", "for_item_ids", "with_id" ]
          }
        }
      end

      def call(args, context)
        trader = ::Character.find_by(id: args["trader_id"] || ::Player.first&.id)
        other  = ::Character.find_by(id: args["with_id"])
        item   = ::Item.find_by(id: args["item_id"])
        wares  = ::Item.where(id: Array(args["for_item_ids"])).to_a
        coins  = [ args["coins"].to_i, 0 ].max
        return { "error" => "trader required" } unless trader
        return { "error" => "no character with id=#{args['with_id']}" } unless other
        return { "error" => "no item with id=#{args['item_id']}" } unless item
        return { "error" => "#{trader.name} does not carry #{item.name}" } unless item.character_id == trader.id
        return { "error" => "nothing named to take in return" } if wares.empty?
        return { "error" => "#{other.name} is not here" } unless other.location_id == trader.location_id
        return { "error" => "#{trader.name} has #{trader.coins.to_i} coins, not #{coins}" } if trader.coins.to_i < coins

        loc = trader.location
        wares.each do |w|
          props = w.properties.is_a?(Hash) ? w.properties : {}
          return { "error" => "#{w.name} is not on the table here" } unless props["for_sale"] && w.location_id == loc&.id
          return { "error" => "#{w.name} is not #{other.name}'s to trade" } unless theirs?(w, other, loc)
        end

        facts    = ::Harness::Settlement::Facts.for(loc)
        given    = ::Harness::Economy::Pricing.sell_price(item, wealth: facts["wealth"], economic_basis: facts["economic_basis"]) + coins
        received = wares.sum { |w| ::Harness::Tools::QueryScene.shop_price(w, loc) }
        if given < received
          offered = coins > 0 ? "#{item.name} and #{coins} coins" : item.name
          return { "error" => "#{other.name} won't take #{offered} (#{given}) for #{wares.map(&:name).join(' and ')} (#{received})" }
        end

        ::ActiveRecord::Base.transaction do
          item.update!(character_id: other.id, location_id: nil)
          if coins > 0
            trader.update!(coins: trader.coins - coins)
            other.update!(coins: other.coins.to_i + coins)
          end
          wares.each do |w|
            props = w.properties.is_a?(Hash) ? w.properties.dup : {}
            %w[for_sale seller_id haggled_price].each { |k| props.delete(k) }
            w.update!(location_id: nil, character_id: trader.id, properties: props)
          end
        end
        log_event(trader, other, item, wares, coins, context)

        { "item_id" => item.id, "item_name" => item.name, "with_id" => other.id, "with_name" => other.name, "coins" => coins,
          "received" => wares.map { |w| { "id" => w.id, "name" => w.name } },
          "value_given" => given, "value_received" => received }
      end

      private

      def theirs?(ware, other, loc)
        props = ware.properties.is_a?(Hash) ? ware.properties : {}
        return props["seller_id"] == other.id if props["seller_id"]
        return true if other.respond_to?(:home_location_id) && other.home_location_id == loc&.id
        trade = loc&.properties.is_a?(Hash) ? loc.properties["trade"].to_s : ""
        !trade.empty? && other.subrole.to_s.downcase.include?(trade.downcase)
      end

      def log_event(trader, other, item, wares, coins, context)
        names = wares.map(&:name).join(" and ")
        gave  = coins > 0 ? "#{item.name} and #{coins} coins" : item.name
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  trader.location,
          details: {
            "summary"     => "#{trader.name} traded #{gave} to #{other.name} for #{names}",
            "trade_items" => { "trader_id" => trader.id, "with_id" => other.id, "item_id" => item.id, "for_item_ids" => wares.map(&:id), "coins" => coins }
          },
          participants: [ { character: trader, role: "trader" }, { character: other, role: "trader" } ]
        )
      end
    end
  end
end
