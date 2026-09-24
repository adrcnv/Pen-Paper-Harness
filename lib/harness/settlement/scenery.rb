module Harness
  module Settlement
    # The nameless places a settlement has without anyone building them (see
    # scenery.yml). Keyed like the manifest: at most one of each per
    # settlement, minted lazily under the root on first need.
    module Scenery
      PATH = Rails.root.join("lib/harness/settlement/scenery.yml")
      Spec = Struct.new(:key, :gloss, :names, :description, keyword_init: true)

      class << self
        def specs
          @specs ||= YAML.safe_load(File.read(PATH)).map { |t|
            Spec.new(key: t["key"].to_s, gloss: t["gloss"].to_s, names: Array(t["names"]), description: t["description"].to_s)
          }.freeze
        end

        def keys = specs.map(&:key)

        def spec(key) = specs.find { |s| s.key == key.to_s }

        # The settlement's row for `key`, minted once → [row, minted?]; nil
        # for an unknown key.
        def find_or_mint!(settlement:, key:, rng: ::Harness::RNG.scene, logger: Rails.logger)
          spec = spec(key)
          return nil unless spec
          existing = ::Location.where(parent_id: settlement.id).detect { |l|
            l.properties.is_a?(::Hash) && l.properties["scenery_key"] == spec.key
          }
          return [ existing, false ] if existing
          loc = ::Location.create!(
            name:        spec.names[rng.rand(spec.names.size)],
            description: spec.description,
            parent_id:   settlement.id,
            properties:  { "kind" => "sublocation", "scenery_key" => spec.key }
          )
          logger.info { "[Settlement::Scenery] minted #{loc.name.inspect} (#{spec.key}) under #{settlement.name}" }
          [ loc, true ]
        end
      end
    end
  end
end
