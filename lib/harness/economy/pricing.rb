module Harness
  module Economy
    # Turns an item's intrinsic worth (Items::Value) into the price a specific
    # SETTLEMENT will buy or sell it for. Two levers, both mechanical:
    #
    #   wealth  — a richer town has pricier wares AND pays better for loot.
    #   basis   — supply/demand. A town that PRODUCES an item's category has it
    #             in supply: cheaper to buy there, and it pays you less for more
    #             of the same. A town that LACKS it pays a premium and charges
    #             one. (Gear-only for now; the rich version of this loop wants
    #             trade-good items — see the items rework. The hook is here so
    #             it just works once those exist.)
    #
    # The buy/sell SPREAD (SELL_FRACTION) is the merchant's margin — the coin
    # sink that makes the trade loop a loop instead of free money.
    module Pricing
      WEALTH_MULT = {
        "poor" => 0.8, "modest" => 1.0, "comfortable" => 1.2, "rich" => 1.5
      }.freeze

      SELL_FRACTION = 0.5   # you sell to a merchant for ~half what you'd buy it back for

      # Which item categories (by tag) a settlement's economic basis produces
      # locally. Only metalworking-adjacent bases make gear today; everything
      # else "imports" it. Extend as trade-good items land.
      BASIS_PRODUCES = {
        "mining"    => %w[weapon armor],
        "quarrying" => %w[armor]
      }.freeze

      LOCAL_FACTOR  = 0.8   # produced here → abundant → cheaper to buy, less paid on sell
      IMPORT_FACTOR = 1.2   # not produced → scarce → dearer to buy, more paid on sell

      module_function

      # What the player PAYS to buy `item` from a shop in this settlement.
      def buy_price(item, wealth:, economic_basis:)
        base = ::Harness::Items::Value.of(item)
        price(base, wealth, economic_basis, item)
      end

      # What a shop PAYS the player to sell them `item`.
      def sell_price(item, wealth:, economic_basis:)
        base = ::Harness::Items::Value.of(item) * SELL_FRACTION
        price(base, wealth, economic_basis, item)
      end

      def price(base, wealth, basis, item)
        mult = wealth_mult(wealth) * basis_factor(basis, item)
        [ (base * mult).round, 1 ].max
      end

      def wealth_mult(wealth)
        WEALTH_MULT.fetch(wealth.to_s, 1.0)
      end

      def basis_factor(basis, item)
        produced_locally?(basis, item) ? LOCAL_FACTOR : IMPORT_FACTOR
      end

      def produced_locally?(basis, item)
        produces = BASIS_PRODUCES[basis.to_s] || []
        return false if produces.empty?
        tags = Array(item.properties.is_a?(Hash) ? item.properties["tags"] : nil)
        (produces & tags).any?
      end
    end
  end
end
