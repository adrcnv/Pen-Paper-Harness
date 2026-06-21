module Harness
  module Worldgen
    # Result of a worldgen pass. Pure data — no DB writes, no LLM bindings.
    # Pass 2 (LLM naming + persistence) consumes this struct and produces
    # actual rows.
    # `geography` is the Worldgen::Geography the cities were placed on (present
    # for a freshly generated map; reconstructed by FromDb from the persisted
    # World row). Persister writes it to the `worlds` table; Ascii renders its
    # rivers/coast/terrain. nil for hand-built test maps that don't need it.
    Map = Struct.new(
      :seed, :size, :cities, :kingdoms, :geography,
      keyword_init: true
    )
  end
end
