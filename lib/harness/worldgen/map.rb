module Harness
  module Worldgen
    # Result of a worldgen pass. Pure data — no DB writes, no LLM bindings.
    # Pass 2 (LLM naming + persistence) consumes this struct and produces
    # actual rows.
    Map = Struct.new(
      :seed, :size, :cities, :kingdoms,
      keyword_init: true
    )
  end
end
