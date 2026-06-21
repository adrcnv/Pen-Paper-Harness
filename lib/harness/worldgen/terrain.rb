module Harness
  module Worldgen
    # Terrain-type classification, layered on top of Geography's per-point
    # queries (elevation / sea? / coastal? / riverside? / moisture). This is the
    # richer successor to Biome's two-value lowland/highland split: it crosses an
    # elevation TIER with a moisture BAND and water adjacency to name the land.
    #
    #   elevation tier (normalized land height above sea):
    #     low → upland → high → peak
    #   moisture band:
    #     dry → moderate → wet
    #
    # The enum (confirmed taxonomy):
    #   land:  coastal · river_valley · marsh · floodplain · grassland ·
    #          moor · forest_lowland · forest_upland · crags · mountain
    #   water: sea (open water; .at returns it) · river · lake
    #
    # `.at` returns SEA for open water and a land type otherwise. The two
    # remaining water types — `river` and `lake` — are geometry, not areas: a
    # river is a polyline (`geo.rivers`) and a lake is a basin endpoint
    # (`geo.lakes`). They're surfaced for rendering / proximity, not returned by
    # the point classifier (a continuous point is essentially never exactly on a
    # river; `riverside?` is the area signal, and it routes points to
    # river_valley / floodplain / marsh).
    module Terrain
      SEA            = :sea
      COASTAL        = :coastal
      RIVER_VALLEY   = :river_valley
      MARSH          = :marsh
      FLOODPLAIN     = :floodplain
      GRASSLAND      = :grassland
      MOOR           = :moor
      FOREST_LOWLAND = :forest_lowland
      FOREST_UPLAND  = :forest_upland
      CRAGS          = :crags
      MOUNTAIN       = :mountain

      RIVER          = :river
      LAKE           = :lake

      LAND  = [ COASTAL, RIVER_VALLEY, MARSH, FLOODPLAIN, GRASSLAND,
                MOOR, FOREST_LOWLAND, FOREST_UPLAND, CRAGS, MOUNTAIN ].freeze
      WATER = [ SEA, RIVER, LAKE ].freeze
      ALL   = (LAND + WATER).freeze

      # Elevation tiers, on land height normalized to [0,1] above sea level.
      TIER_LOW    = 0.30   # h <  this  → low flatland
      TIER_UPLAND = 0.62   # h <  this  → rolling upland
      TIER_HIGH   = 0.85   # h <  this  → high/rocky;  >= → peak

      # Moisture bands.
      BAND_DRY = 0.38      # m <  this → dry
      BAND_WET = 0.62      # m >= this → wet;  between → moderate

      # Settlement habitability — how readily a town wants to sit on this
      # terrain. Drives geography-aware city placement (chunk 3) and the eventual
      # settlement-profile weighting. 0 = uninhabitable, 1 = prime ground.
      HABITABILITY = {
        COASTAL        => 1.0,   # ports
        FLOODPLAIN     => 1.0,   # fertile, watered farmland
        RIVER_VALLEY   => 0.95,
        GRASSLAND      => 0.85,
        FOREST_LOWLAND => 0.7,
        MOOR           => 0.45,
        FOREST_UPLAND  => 0.45,
        MARSH          => 0.3,
        CRAGS          => 0.2,
        MOUNTAIN       => 0.05,
        SEA            => 0.0
      }.freeze

      # Travel-cost multiplier per terrain (successor to Biome.cost_multiplier).
      COST = {
        COASTAL        => 1.0,
        FLOODPLAIN     => 1.0,
        GRASSLAND      => 1.0,
        RIVER_VALLEY   => 1.1,
        FOREST_LOWLAND => 1.4,
        MOOR           => 1.5,
        MARSH          => 1.8,
        FOREST_UPLAND  => 1.8,
        CRAGS          => 2.4,
        MOUNTAIN       => 3.2,
        SEA            => 1.0   # not traversable on foot; placeholder
      }.freeze

      module_function

      # Classify a point. Returns SEA for open water, else a land terrain symbol.
      def at(geo:, x:, y:)
        return SEA if geo.sea?(x, y)

        h    = land_height(geo, x, y)
        tier = elevation_tier(h)

        case tier
        when :peak then MOUNTAIN
        when :high then CRAGS
        when :upland
          return COASTAL      if geo.coastal?(x, y)
          return RIVER_VALLEY if geo.riverside?(x, y)
          case moisture_band(geo.moisture(x, y))
          when :wet      then FOREST_UPLAND
          when :moderate then MOOR
          else                GRASSLAND
          end
        else # :low
          return COASTAL if geo.coastal?(x, y)
          band = moisture_band(geo.moisture(x, y))
          if geo.riverside?(x, y)
            return band == :wet ? MARSH : FLOODPLAIN
          end
          return MARSH if band == :wet
          band == :moderate ? FOREST_LOWLAND : GRASSLAND
        end
      end

      def cost_multiplier(terrain)
        COST.fetch(terrain, 1.0)
      end

      def habitability(terrain)
        HABITABILITY.fetch(terrain, 0.0)
      end

      # Land elevation rescaled to [0,1] above sea level (0 at the waterline,
      # 1 at the map's ceiling). Sea points clamp to 0.
      def land_height(geo, x, y)
        span = 1.0 - geo.sea_level
        return 0.0 if span <= 0
        ((geo.elevation(x, y) - geo.sea_level) / span).clamp(0.0, 1.0)
      end

      def elevation_tier(h)
        if    h < TIER_LOW    then :low
        elsif h < TIER_UPLAND then :upland
        elsif h < TIER_HIGH   then :high
        else                       :peak
        end
      end

      def moisture_band(m)
        if    m < BAND_DRY then :dry
        elsif m < BAND_WET then :moderate
        else                    :wet
        end
      end
    end
  end
end
