module Harness
  module Worldgen
    # A Faction (is_kingdom: true) candidate. anchor_city_id is the city the
    # Voronoi cell was seeded from — useful as the kingdom's capital later.
    # culture_id is rolled during the naming pass (so mechanical place names
    # draw from the kingdom's culture) and read back by the Persister.
    Kingdom = Struct.new(
      :id, :anchor_city_id, :name, :description, :culture_id,
      keyword_init: true
    )
  end
end
