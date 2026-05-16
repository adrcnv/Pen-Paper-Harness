module Harness
  module Worldgen
    # A parentless top-level Location candidate. Pass 2 turns this into an
    # actual Location row with `name`, `description`, `x`, `y`, `biome`, and
    # `faction_id` (kingdom).
    City = Struct.new(
      :id, :x, :y, :biome, :kingdom_id, :name, :description,
      keyword_init: true
    )
  end
end
