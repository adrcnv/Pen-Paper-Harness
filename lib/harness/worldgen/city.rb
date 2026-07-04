module Harness
  module Worldgen
    # A parentless top-level Location candidate. Pass 2 turns this into an
    # actual Location row with `name`, `description`, `x`, `y`, `biome`, and
    # `faction_id` (kingdom).
    #
    # `biome` stays the coarse lowland/highland fact (legacy consumers: tags,
    # cost fallback). `terrain` / `coastal` / `riverside` are the
    # richer geography facts denormalized onto the city for settlement profiles
    # and rendering — sampled from Worldgen::Geography at placement.
    # `economic_basis` / `size` / `wealth` are the mechanical settlement profile
    # (Harness::Settlement::Profile), rolled at persist time and read back by
    # FromDb for /map display. nil on a freshly generated (unpersisted) map.
    City = Struct.new(
      :id, :x, :y, :biome, :kingdom_id, :name, :description,
      :terrain, :coastal, :riverside,
      :economic_basis, :size, :wealth,
      keyword_init: true
    )
  end
end
