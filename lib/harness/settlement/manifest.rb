require "yaml"

module Harness
  module Settlement
    # Profile → the KNOWN SHAPE of a settlement: which sublocations it should
    # have. Reads the data table (manifest.yml), filters by the city's economic
    # profile (basis × size × wealth), and returns one spec per eligible
    # sublocation. Pure mechanical, no LLM — the type/shape is mechanical; the
    # LLM only dresses the contents later (Scene::Materializer on approach).
    #
    # A `Spec` is a concrete sublocation to create: a chosen name, the
    # proprietor subrole hint, and stub description. Layout turns these into
    # Location rows; the Materializer reads name+description to populate them.
    module Manifest
      TABLE_PATH = Rails.root.join("lib/harness/settlement/manifest.yml")

      # `shop` is the list of item categories this sublocation buys/sells
      # (nil for non-commercial places). Drives Economy::ShopStock + buy/sell.
      Spec = Struct.new(:key, :name, :subrole, :description, :shop, keyword_init: true)

      class << self
        # Eligible sublocation specs for a settlement profile. `rng` drives the
        # name-pool pick so a given world is stable when seeded.
        def for(economic_basis:, size:, wealth:, rng: Random.new)
          templates = candidate_templates(economic_basis)
          templates
            .select { |t| eligible?(t, size, wealth) }
            .uniq   { |t| t["key"] }                       # one per key (e.g. one Smithy)
            .map    { |t| build_spec(t, rng) }
        end

        private

        def candidate_templates(basis)
          d = data
          basis_rows = (d["by_basis"] || {})[basis.to_s] || []
          (d["universal"] || []) + (d["by_size"] || []) + (d["by_wealth"] || []) + basis_rows
        end

        def eligible?(template, size, wealth)
          size_ok?(template["min_size"], size) && wealth_ok?(template["min_wealth"], wealth)
        end

        def size_ok?(min_size, size)
          return true if min_size.nil?
          tier_index(Profile::SIZES, size) >= tier_index(Profile::SIZES, min_size)
        end

        def wealth_ok?(min_wealth, wealth)
          return true if min_wealth.nil?
          tier_index(Profile::WEALTH_TIERS, wealth) >= tier_index(Profile::WEALTH_TIERS, min_wealth)
        end

        # Index of a tier in its ordered list; unknown values sort lowest so a
        # missing/garbled value never spuriously clears a min_* gate.
        def tier_index(order, value)
          order.index(value.to_s) || -1
        end

        def build_spec(template, rng)
          names = Array(template["names"])
          name  = names.empty? ? template["key"].to_s.tr("_", " ") : names.sample(random: rng)
          Spec.new(
            key:         template["key"],
            name:        name,
            subrole:     template["subrole"],
            description: template["description"],
            shop:        template["shop"]
          )
        end

        def data
          @data ||= YAML.safe_load_file(TABLE_PATH)
        end
      end
    end
  end
end
