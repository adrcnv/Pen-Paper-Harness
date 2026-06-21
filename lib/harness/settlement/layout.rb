module Harness
  module Settlement
    # Lay out a settlement's KNOWN SHAPE: create the manifest's sublocations as
    # child Location stubs of the city, on first entry. "Pre-generate the shape,
    # materialize the contents on approach" — these rows carry only a name +
    # trade-signalling description; their proprietor NPCs/items fill in when the
    # player actually walks into each (Scene::Materializer reads name+description
    # to spawn the right person — a stub called "the Smithy" gets a smith).
    #
    # Pure mechanical (no LLM). Idempotent via the city's `settlement_laid_out`
    # flag AND a per-row `manifest_key` guard, so it never duplicates a wing the
    # player (or quest gen) already created. Only fires for worldgen cities that
    # carry an economic profile; hand-authored fixtures and pre-geography saves
    # have none and are left alone.
    module Layout
      class << self
        # Returns the Location rows created (empty if already laid out / no
        # profile). `rng` drives the manifest name-pool picks.
        def lay_out!(city:, rng: Random.new, logger: Rails.logger)
          return [] unless city
          props = city.properties.is_a?(Hash) ? city.properties : {}
          return [] if props["settlement_laid_out"]

          basis = props["economic_basis"]
          return [] if basis.nil?   # no profile (fixture / pre-geography) — nothing to lay out

          specs = Manifest.for(
            economic_basis: basis,
            size:           props["size"],
            wealth:         props["wealth"],
            rng:            rng
          )

          existing_keys = child_manifest_keys(city)
          created = specs.reject { |s| existing_keys.include?(s.key.to_s) }
                         .map    { |s| create_stub(city, s) }

          mark_laid_out!(city)
          logger.info { "[Settlement::Layout] #{city.name}: laid out #{created.size} sublocations (#{specs.size} in manifest)" }
          created
        rescue StandardError => e
          logger.warn { "[Settlement::Layout] failed for #{city&.name}: #{e.class}: #{e.message}" }
          []
        end

        private

        def child_manifest_keys(city)
          ::Location.where(parent_id: city.id).filter_map do |c|
            c.properties["manifest_key"] if c.properties.is_a?(Hash)
          end.map(&:to_s)
        end

        def create_stub(city, spec)
          props = {
            "kind"         => "sublocation",
            "manifest_key" => spec.key.to_s,
            "trade"        => spec.subrole
          }
          props["shop"] = spec.shop if spec.shop   # categories this place buys/sells
          ::Location.create!(
            name:        spec.name,
            description: spec.description,
            parent_id:   city.id,
            properties:  props
          )
        end

        def mark_laid_out!(city)
          props = (city.properties.is_a?(Hash) ? city.properties : {}).dup
          props["settlement_laid_out"] = true
          city.update!(properties: props)
        end
      end
    end
  end
end
