module Harness
  module Settlement
    # The mechanical economic IDENTITY of a settlement — the antidote to the LLM
    # "every-town-averages-to-generic-fantasy-village" failure mode. Three axes,
    # rolled mechanically from the city's geography (terrain + coastal/riverside)
    # at worldgen, then handed to the LLM only as TEXTURE (same pattern as
    # mechanical naming + items: the core picks the TYPE, the model dresses it).
    #
    #   economic_basis — how the town makes its money. Terrain-weighted, so the
    #     long-tail evocative trades (charcoal, salt, peat, quarry) appear at
    #     their MECHANICAL rate, not the LLM's averaging rate. THIS is what lets
    #     a charcoal-burner hamlet or a salt-panning coast town actually exist.
    #   size           — hamlet → village → town → city. Zipf-ish (most are
    #     small); prosperous terrain can support bigger. Drives how many
    #     sublocations/services the settlement should have (manifest, next step).
    #   wealth         — poor → modest → comfortable → rich. Derived from
    #     size + basis tendency + a roll. Drives prices + which merchants exist.
    #
    # Downstream: (basis × size) → a known sublocation/trade MANIFEST; wealth +
    # basis → shops, prices, supply/demand. None of that is here yet — this is
    # the seed those read.
    module Profile
      # Canonical economic bases. Free-text-ish for LLM archetype inference, but
      # drawn from this fixed set so downstream manifests can switch on them.
      BASES = %w[
        fishing port salt river_trade farming milling herding market
        logging charcoal mining quarrying peat frontier
      ].freeze

      SIZES        = %w[hamlet village town city].freeze
      WEALTH_TIERS = %w[poor modest comfortable rich].freeze

      # Base economic weighting per land terrain. Water adjacency (coastal/
      # riverside) layers ON TOP via boosts, so a coastal grassland leans both
      # fishing/port AND farming — a mixed economy, mechanically.
      TERRAIN_BASES = {
        "coastal"        => { "fishing" => 4, "port" => 3, "salt" => 2, "market" => 1, "farming" => 1 },
        "river_valley"   => { "river_trade" => 3, "farming" => 3, "milling" => 2, "market" => 1, "herding" => 1 },
        "floodplain"     => { "farming" => 5, "milling" => 2, "market" => 1, "herding" => 1 },
        "grassland"      => { "farming" => 3, "herding" => 3, "market" => 2, "milling" => 1 },
        "marsh"          => { "peat" => 3, "fishing" => 2, "herding" => 1 },
        "moor"           => { "herding" => 3, "peat" => 2, "mining" => 1 },
        "forest_lowland" => { "logging" => 3, "charcoal" => 2, "farming" => 1, "market" => 1 },
        "forest_upland"  => { "logging" => 3, "charcoal" => 3, "mining" => 1 },
        "crags"          => { "mining" => 4, "quarrying" => 3, "herding" => 1 },
        "mountain"       => { "mining" => 3, "quarrying" => 2, "frontier" => 1 }
      }.freeze

      # Fallback weighting when terrain is unknown (pre-geography saves).
      DEFAULT_BASES = { "farming" => 3, "herding" => 2, "market" => 1 }.freeze

      COASTAL_BOOST   = { "fishing" => 3, "port" => 2, "salt" => 1 }.freeze
      RIVERSIDE_BOOST = { "river_trade" => 2, "milling" => 1, "farming" => 1 }.freeze

      SIZE_WEIGHTS = { "hamlet" => 45, "village" => 30, "town" => 18, "city" => 7 }.freeze
      # Fertile / trade-favoured terrain can grow past a frontier hamlet.
      PROSPEROUS_TERRAINS = %w[coastal floodplain river_valley grassland].freeze

      SIZE_SCORE = { "hamlet" => 0, "village" => 1, "town" => 2, "city" => 3 }.freeze
      BASIS_WEALTH = {
        "port" => 2, "market" => 2, "river_trade" => 2, "mining" => 2, "quarrying" => 2, "salt" => 2,
        "farming" => 1, "milling" => 1, "fishing" => 1, "logging" => 1,
        "herding" => 0, "charcoal" => 0, "peat" => 0, "frontier" => 0
      }.freeze

      module_function

      # Roll a profile from geography facts. Returns a string-keyed hash ready to
      # merge straight into Location#properties.
      def roll(terrain:, coastal: false, riverside: false, rng: Random.new)
        basis = roll_basis(terrain, coastal, riverside, rng)
        size  = roll_size(terrain, rng)
        {
          "economic_basis" => basis,
          "size"           => size,
          "wealth"         => roll_wealth(basis, size, rng)
        }
      end

      def roll_basis(terrain, coastal, riverside, rng)
        weights = (TERRAIN_BASES[terrain.to_s] || DEFAULT_BASES).dup
        merge_weights!(weights, COASTAL_BOOST)   if coastal
        merge_weights!(weights, RIVERSIDE_BOOST) if riverside
        weighted_pick(weights, rng)
      end

      def roll_size(terrain, rng)
        weights = SIZE_WEIGHTS.dup
        if PROSPEROUS_TERRAINS.include?(terrain.to_s)
          weights["town"] *= 2   # fertile/trade ground can support more than a frontier hamlet
          weights["city"] *= 2
        end
        weighted_pick(weights, rng)
      end

      def roll_wealth(basis, size, rng)
        score = SIZE_SCORE.fetch(size, 0) + BASIS_WEALTH.fetch(basis, 0) + rng.rand(0..2)
        if    score <= 1 then "poor"
        elsif score <= 3 then "modest"
        elsif score <= 5 then "comfortable"
        else                  "rich"
        end
      end

      def merge_weights!(into, boost)
        boost.each { |k, v| into[k] = into.fetch(k, 0) + v }
        into
      end

      # Deterministic-given-rng weighted choice over a {value => weight} hash.
      def weighted_pick(weights, rng)
        total  = weights.values.sum
        target = rng.rand(total) + 1
        cum = 0
        weights.each do |value, weight|
          cum += weight
          return value if target <= cum
        end
        weights.keys.last # defensive; unreachable
      end
    end
  end
end
