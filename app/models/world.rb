# Singleton row holding the generated world's geography metadata. One per save
# file. Exists so geography survives a restart: the seed reconstructs the
# continuous fields (elevation / sea / moisture) and the cached `rivers`
# polylines restore the only precomputed artifact without re-walking.
#
# Read path for runtime systems that want terrain at an arbitrary point
# (travel cost, future settlement profiles, /map): `World.geography` hands back
# a reconstructed Harness::Worldgen::Geography; `World.terrain_at` /
# `World.cost_multiplier_at` are convenience wrappers that return nil when no
# world is recorded (callers then fall back to the coarse `biome`).
class World < ApplicationRecord
  def self.current
    first
  end

  # Persist (or replace) the singleton from a built Geography.
  def self.record!(geo)
    delete_all
    create!(
      seed:        geo.seed.to_s,
      size:        geo.size,
      sea_level:   geo.sea_level,
      river_count: geo.rivers.size,
      rivers:      geo.rivers_payload
    )
  end

  def self.geography
    current&.geography
  end

  def self.terrain_at(x, y)
    g = geography
    g && ::Harness::Worldgen::Terrain.at(geo: g, x: x, y: y)
  end

  # Travel-cost multiplier at a point, or nil if no world is recorded.
  def self.cost_multiplier_at(x, y)
    t = terrain_at(x, y)
    t && ::Harness::Worldgen::Terrain.cost_multiplier(t)
  end

  def geography
    @geography ||= ::Harness::Worldgen::Geography.restore(
      seed:      seed,
      size:      size,
      sea_level: sea_level,
      rivers:    rivers
    )
  end
end
