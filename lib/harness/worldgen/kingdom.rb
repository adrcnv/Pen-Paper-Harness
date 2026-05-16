module Harness
  module Worldgen
    # A Faction (is_kingdom: true) candidate. anchor_city_id is the city the
    # Voronoi cell was seeded from — useful as the kingdom's capital later.
    Kingdom = Struct.new(
      :id, :anchor_city_id, :name, :description,
      keyword_init: true
    )
  end
end
