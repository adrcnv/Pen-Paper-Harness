require "yaml"

module Harness
  module Quests
    # Loads + validates quest archetype YAMLs and exposes filtering / weighted
    # pick. Same shape as Harness::Items::Library — boot-time load, hard fail
    # on malformed YAML, weighted pick at runtime.
    #
    # Each archetype YAML lives at lib/harness/quests/library/<id>.yml and
    # describes a quest skeleton (slots, ordered steps, city tags, weight,
    # prompt seed). The Generator picks one archetype by weight (filtered by
    # city tags), then hands it to the authoring LLM call to fill in names
    # and prose.
    module Library
      LIBRARY_DIR = Rails.root.join("lib/harness/quests/library")

      ALLOWED_SLOT_KINDS         = %w[character item location].freeze
      ALLOWED_FULFILLMENT_KINDS  = %w[information item_in_inventory character_dead character_at_location].freeze

      class InvalidLibrary < StandardError; end

      class << self
        # All archetypes that have at least one city_tag in common with the
        # passed-in tags (or archetypes with empty city_tags — those fit
        # anywhere). Returns an array of archetype hashes.
        def for_city_tags(tags)
          load!
          tag_set = Set.new(Array(tags).map(&:to_s))
          @archetypes.select do |a|
            a["city_tags"].empty? || a["city_tags"].any? { |t| tag_set.include?(t) }
          end
        end

        # Weighted pick from an array of archetypes. Returns nil for empty input.
        def weighted_pick(archetypes, rng: Random.new)
          return nil if archetypes.empty?
          total  = archetypes.sum { |a| a["weight"].to_i }
          return nil if total <= 0
          target = rng.rand(total) + 1
          cum    = 0
          archetypes.each do |a|
            cum += a["weight"].to_i
            return a if target <= cum
          end
          archetypes.last
        end

        def find(id)
          load!
          @by_id[id.to_s]
        end

        def all
          load!
          @archetypes
        end

        def reload!
          @archetypes = nil
          @by_id      = nil
        end

        private

        def load!
          return if @archetypes
          @archetypes = []
          @by_id      = {}

          Dir.glob(LIBRARY_DIR.join("*.yml")).sort.each do |path|
            raw = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
            raise InvalidLibrary, "#{path}: expected top-level Hash" unless raw.is_a?(Hash)
            validate!(raw, path)
            raise InvalidLibrary, "duplicate archetype id=#{raw['id']}" if @by_id.key?(raw["id"])
            @archetypes << raw
            @by_id[raw["id"]] = raw
          end
        end

        def validate!(a, path)
          %w[id city_tags weight prompt_seed slots steps].each do |f|
            raise InvalidLibrary, "#{path}: missing #{f}" if a[f].nil?
          end
          raise InvalidLibrary, "#{path}: id must be String"         unless a["id"].is_a?(String) && !a["id"].empty?
          raise InvalidLibrary, "#{path}: city_tags must be Array"   unless a["city_tags"].is_a?(Array)
          raise InvalidLibrary, "#{path}: weight must be Integer >0" unless a["weight"].is_a?(Integer) && a["weight"] > 0
          raise InvalidLibrary, "#{path}: prompt_seed must be String" unless a["prompt_seed"].is_a?(String)
          validate_slots!(a["slots"], path)
          validate_steps!(a["steps"], a["slots"], path)
        end

        def validate_slots!(slots, path)
          raise InvalidLibrary, "#{path}: slots must be Array" unless slots.is_a?(Array)
          slots.each_with_index do |s, i|
            p = "#{path}: slots[#{i}]"
            raise InvalidLibrary, "#{p}: must be Hash" unless s.is_a?(Hash)
            %w[id kind count].each { |f| raise InvalidLibrary, "#{p}: missing #{f}" if s[f].nil? }
            raise InvalidLibrary, "#{p}: kind=#{s['kind'].inspect} not in #{ALLOWED_SLOT_KINDS}" unless ALLOWED_SLOT_KINDS.include?(s["kind"])
            raise InvalidLibrary, "#{p}: count must be Integer >= 1" unless s["count"].is_a?(Integer) && s["count"] >= 1
          end
          ids = slots.map { |s| s["id"] }
          raise InvalidLibrary, "#{path}: duplicate slot ids" if ids.uniq.size != ids.size
        end

        def validate_steps!(steps, slots, path)
          raise InvalidLibrary, "#{path}: steps must be Array" unless steps.is_a?(Array)
          raise InvalidLibrary, "#{path}: steps must be non-empty" if steps.empty?
          slot_ids = slots.map { |s| s["id"] }.to_set
          steps.each_with_index do |s, i|
            p = "#{path}: steps[#{i}]"
            raise InvalidLibrary, "#{p}: must be Hash" unless s.is_a?(Hash)
            %w[kind description_hint].each { |f| raise InvalidLibrary, "#{p}: missing #{f}" if s[f].nil? }
            raise InvalidLibrary, "#{p}: kind=#{s['kind'].inspect} not in #{ALLOWED_FULFILLMENT_KINDS}" unless ALLOWED_FULFILLMENT_KINDS.include?(s["kind"])
            validate_step_slot_refs!(s, slot_ids, p)
          end
        end

        def validate_step_slot_refs!(step, slot_ids, p)
          # target_slot / location_slot can be `slot_id` or `slot_id[index]`;
          # extract bare slot id and check membership.
          %w[target_slot location_slot].each do |k|
            v = step[k]
            next if v.nil?
            slot_id = v.to_s.split("[").first
            raise InvalidLibrary, "#{p}: #{k}=#{v.inspect} references unknown slot" unless slot_ids.include?(slot_id)
          end
        end
      end
    end
  end
end
