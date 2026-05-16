require "json"

module Harness
  module Worldgen
    module Naming
      module Prompt
        SYSTEM_PATH = Rails.root.join("lib/harness/prompts/worldgen_naming.txt")

        # Returns [system, user] strings. Caller passes these to
        # `llm.complete(system: ..., user: ...)` so the system head can be
        # cached across the per-kingdom calls in a single worldgen pass.
        def self.build(kingdom:, members:)
          [ system, user(kingdom: kingdom, members: members) ]
        end

        def self.system
          File.read(SYSTEM_PATH)
        end

        def self.user(kingdom:, members:)
          payload = {
            "kingdom_id"        => kingdom.id,
            "anchor_position"   => position(members.find { |c| c.id == kingdom.anchor_city_id }),
            "biome_mix"         => biome_mix(members),
            "cities"            => members.map { |c|
              {
                "id"         => c.id,
                "position"   => position(c),
                "biome"      => c.biome,
                "is_anchor"  => c.id == kingdom.anchor_city_id
              }
            }
          }
          "INPUT:\n#{JSON.pretty_generate(payload)}"
        end

        def self.position(city)
          { "x" => city.x.round(1), "y" => city.y.round(1) }
        end

        def self.biome_mix(members)
          counts = Hash.new(0)
          members.each { |c| counts[c.biome] += 1 }
          counts
        end
      end
    end
  end
end
