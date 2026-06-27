module Harness
  module Worldgen
    # Roll the mechanical settlement profile (economic_basis / size / wealth)
    # onto each City BEFORE naming, so the description pass can ground its prose
    # in the real size — a hamlet reads humble, not "grand capital." Previously
    # the profile was rolled in the Persister, AFTER naming, so the description
    # LLM literally could not see the size (it didn't exist yet).
    #
    # Anchors — each kingdom's principal city — are floored to >= town, so the
    # realm's seat is a settlement of consequence rather than a randomly-sized
    # hamlet that the prompt is then told to glorify (anchors are picked at
    # random in Voronoi v1, independent of size).
    #
    # Seeded from the world seed → reproducible profiles for a given world (the
    # old Persister roll used an unseeded Random.new, so profiles weren't even
    # stable across re-persists). SEED_SALT keeps this stream independent of the
    # geometry/naming rng so adding it doesn't shift those.
    module Profiler
      ANCHOR_SIZE_FLOOR = "town"
      SEED_SALT = 0x50524F46 # "PROF"

      def self.assign!(map:)
        rng        = Random.new(map.seed.to_i ^ SEED_SALT)
        anchor_ids = map.kingdoms.map(&:anchor_city_id).compact.to_set
        map.cities.each do |c|
          profile = ::Harness::Settlement::Profile.roll(
            terrain:    c.terrain,
            coastal:    c.coastal,
            riverside:  c.riverside,
            rng:        rng,
            size_floor: (ANCHOR_SIZE_FLOOR if anchor_ids.include?(c.id))
          )
          c.economic_basis = profile["economic_basis"]
          c.size           = profile["size"]
          c.wealth         = profile["wealth"]
        end
        map
      end
    end
  end
end
