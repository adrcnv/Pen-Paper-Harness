module Harness
  module Economy
    # Stocks a shop sublocation with wares on first entry: rolls
    # category-appropriate items (Items::Generator) and anchors them to the shop
    # location, flagged `for_sale`. Pure mechanical, no LLM — the shop's
    # CATEGORIES come from the manifest (`properties["shop"]`), the count scales
    # with settlement size + wealth. Idempotent via `properties["shop_stocked"]`.
    #
    # Wares are anchored to the location (not owned by the proprietor) so they
    # surface as present_items in the scene and survive proprietor turnover; the
    # buy flow transfers ownership to the player and pays the present merchant.
    module ShopStock
      SIZE_STOCK = { "hamlet" => 1, "village" => 2, "town" => 4, "city" => 6 }.freeze
      WEALTH_BONUS = { "poor" => 0, "modest" => 0, "comfortable" => 1, "rich" => 2 }.freeze

      module_function

      # Returns the items created (empty when not a shop / already stocked).
      def stock!(location, rng: Random.new, logger: Rails.logger)
        return [] unless location
        props = location.properties.is_a?(Hash) ? location.properties : {}
        categories = Array(props["shop"])
        return [] if categories.empty?
        return [] if props["shop_stocked"]

        city  = top_level_city_for(location)
        count = stock_count(city, rng)

        created = Array.new(count).filter_map do
          category = categories.sample(random: rng)
          item = ::Harness::Items::Generator.roll_from_category(category, location: location, rng: rng)
          flag_for_sale!(item)
          item
        end

        mark_stocked!(location)
        logger.info { "[Economy::ShopStock] #{location.name}: stocked #{created.size} wares (#{categories.join('/')})" }
        created
      rescue StandardError => e
        logger.warn { "[Economy::ShopStock] failed for #{location&.name}: #{e.class}: #{e.message}" }
        []
      end

      def stock_count(city, rng)
        cprops = city&.properties.is_a?(Hash) ? city.properties : {}
        base   = SIZE_STOCK.fetch(cprops["size"], 2)
        bonus  = WEALTH_BONUS.fetch(cprops["wealth"], 0)
        base + bonus + rng.rand(0..1)
      end

      def flag_for_sale!(item)
        props = item.properties.is_a?(Hash) ? item.properties.dup : {}
        props["for_sale"] = true
        item.update!(properties: props)
      end

      def mark_stocked!(location)
        props = (location.properties.is_a?(Hash) ? location.properties : {}).dup
        props["shop_stocked"] = true
        location.update!(properties: props)
      end

      def top_level_city_for(loc)
        current = loc
        current = current.parent while current&.parent_id
        current
      end
    end
  end
end
