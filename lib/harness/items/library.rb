require "yaml"

module Harness
  module Items
    # Loads + validates the per-category item YAMLs and exposes weighted
    # picks. Validation runs at boot; bad YAML aborts (same shape as the
    # Scenarios::Roller treatment).
    #
    # Categories are the YAML filenames in lib/harness/items/library/:
    #   weapons.yml, armor.yml, jewelry.yml, magical.yml
    #
    # Each entry contributes a `weight` toward category-level weighted picks.
    # Magical effects reference TriggerRegistry by name; validation rejects
    # unknown trigger names + malformed params.
    module Library
      LIBRARY_DIR = Rails.root.join("lib/harness/items/library")
      CATEGORIES  = %w[weapons armor jewelry magical].freeze

      class InvalidLibrary < StandardError; end

      class << self
        # Returns all entries in a category. Raises if the category isn't
        # known. Caches per-category load.
        def for_category(category)
          load!
          @by_category.fetch(category.to_s) { raise InvalidLibrary, "unknown category=#{category.inspect}" }
        end

        # Weighted random pick from a category. Returns nil if the category
        # is empty (e.g., no magical items added yet).
        def weighted_pick(category, rng: Random.new)
          entries = for_category(category)
          return nil if entries.empty?
          total  = entries.sum { |e| e["weight"].to_i }
          target = rng.rand(total) + 1
          cum    = 0
          entries.each do |e|
            cum += e["weight"].to_i
            return e if target <= cum
          end
          entries.last  # unreachable; defensive
        end

        # Lookup by id across all categories. Returns nil if not found.
        def find(id)
          load!
          @by_id[id.to_s]
        end

        # Test seam — drops the cache so changes to the YAMLs are picked up.
        def reload!
          @by_category = nil
          @by_id       = nil
        end

        private

        def load!
          return if @by_category
          @by_category = {}
          @by_id       = {}
          CATEGORIES.each do |category|
            path = LIBRARY_DIR.join("#{category}.yml")
            raise InvalidLibrary, "missing library: #{path}" unless path.exist?
            entries = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || []
            validate_category!(category, entries)
            @by_category[category] = entries
            entries.each do |e|
              raise InvalidLibrary, "duplicate id=#{e['id']}" if @by_id.key?(e["id"])
              @by_id[e["id"]] = e
            end
          end
        end

        def validate_category!(category, entries)
          raise InvalidLibrary, "category=#{category} must be an array" unless entries.is_a?(Array)
          entries.each_with_index do |e, i|
            prefix = "#{category}[#{i}]"
            %w[id kind_pool flavor_pool base_tags weight].each do |field|
              raise InvalidLibrary, "#{prefix}: missing #{field}" if e[field].nil?
            end
            raise InvalidLibrary, "#{prefix}: weight must be non-negative integer"  unless e["weight"].is_a?(Integer) && e["weight"] >= 0
            raise InvalidLibrary, "#{prefix}: kind_pool must be a non-empty array"  unless e["kind_pool"].is_a?(Array) && e["kind_pool"].any?
            raise InvalidLibrary, "#{prefix}: flavor_pool must be an array"         unless e["flavor_pool"].is_a?(Array)
            raise InvalidLibrary, "#{prefix}: base_tags must be an array"           unless e["base_tags"].is_a?(Array)
            validate_modifier_table!(prefix, e["modifier_table"])
            validate_effect_pool!(prefix,    e["effect_pool"]) if e["effect_pool"]
          end
        end

        def validate_modifier_table!(prefix, table)
          return if table.nil?
          raise InvalidLibrary, "#{prefix}: modifier_table must be an array" unless table.is_a?(Array)
          table.each_with_index do |m, j|
            mp = "#{prefix}.modifier_table[#{j}]"
            raise InvalidLibrary, "#{mp}: must be an object" unless m.is_a?(Hash)
            raise InvalidLibrary, "#{mp}: missing op"        unless m["op"].is_a?(String)
            if m["range"]
              raise InvalidLibrary, "#{mp}: range must be [min, max] integers" unless m["range"].is_a?(Array) && m["range"].size == 2 && m["range"].all? { |n| n.is_a?(Integer) }
            end
          end
        end

        def validate_effect_pool!(prefix, pool)
          raise InvalidLibrary, "#{prefix}: effect_pool must be an array" unless pool.is_a?(Array)
          pool.each_with_index do |effect, j|
            ep = "#{prefix}.effect_pool[#{j}]"
            raise InvalidLibrary, "#{ep}: missing trigger" unless effect["trigger"].is_a?(String)
            raise InvalidLibrary, "#{ep}: missing weight"  unless effect["weight"].is_a?(Integer) && effect["weight"] >= 0
            unless ::Harness::Items::TriggerRegistry.known?(effect["trigger"])
              raise InvalidLibrary, "#{ep}: trigger=#{effect['trigger'].inspect} not in TriggerRegistry"
            end
            begin
              ::Harness::Items::TriggerRegistry.validate_params!(effect["trigger"], effect["params"] || {})
            rescue ::Harness::Items::TriggerRegistry::InvalidParams => e
              raise InvalidLibrary, "#{ep}: #{e.message}"
            end
          end
        end
      end
    end
  end
end
