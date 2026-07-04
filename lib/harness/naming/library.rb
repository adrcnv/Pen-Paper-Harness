require "yaml"

module Harness
  module Naming
    # Loads + validates the culture YAMLs in lib/harness/naming/cultures/.
    # Same boot-time load + hard-fail-on-bad-YAML pattern as
    # Harness::Items::Library.
    #
    # Each culture exposes:
    #   id           — unique string slug ("anglish", "nord", ...)
    #   weight       — integer for kingdom-assignment weighted pick
    #   given_male   — non-empty array of male given names
    #   given_female — non-empty array of female given names
    #   given        — DERIVED at load: given_male + given_female (the
    #                  combined pool; readers that don't care about gender,
    #                  and the gender-agnostic membership checks, use this)
    #   family       — array of family names (can be empty for cultures that
    #                  only use given names)
    #   flavor       — optional human-readable note (debug aid only)
    #
    # The two given pools are kept DISJOINT in the YAML so a name maps to
    # exactly one gender — Naming.gender_for relies on that.
    #
    # Names are sampled uniformly within a culture; the only weight is the
    # PER-KINGDOM assignment of which culture that kingdom uses. Inside a
    # culture, every given/family entry has equal odds — keeps the pools
    # producing variety rather than locking onto a "default" Aelric every
    # spawn.
    module Library
      LIBRARY_DIR = Rails.root.join("lib/harness/naming/cultures")

      class InvalidLibrary < StandardError; end

      class << self
        def all
          load!
          @cultures
        end

        def find(id)
          load!
          @by_id[id.to_s]
        end

        # Weighted pick across all loaded cultures. Used by worldgen to
        # assign one culture per kingdom.
        def weighted_pick(rng: Random.new)
          load!
          total = @cultures.sum { |c| c["weight"].to_i }
          raise InvalidLibrary, "no cultures available for weighted pick" if total <= 0
          target = rng.rand(total) + 1
          cum    = 0
          @cultures.each do |c|
            cum += c["weight"].to_i
            return c if target <= cum
          end
          @cultures.last
        end

        # Fallback when a location has no kingdom in its parent chain (hand-
        # authored fixtures, orphan rows). First alphabetically — deterministic
        # rather than random so the fallback is stable across runs.
        def default
          load!
          @cultures.first
        end

        def reload!
          @cultures = nil
          @by_id    = nil
        end

        private

        def load!
          return if @cultures
          @cultures = []
          @by_id    = {}
          Dir.glob(LIBRARY_DIR.join("*.yml")).sort.each do |path|
            raw = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
            raise InvalidLibrary, "#{path}: expected top-level Hash" unless raw.is_a?(Hash)
            validate!(raw, path)
            # Derived combined pool — gender-agnostic readers use this.
            raw["given"] = Array(raw["given_male"]) + Array(raw["given_female"])
            raise InvalidLibrary, "duplicate culture id=#{raw['id']}" if @by_id.key?(raw["id"])
            @cultures << raw
            @by_id[raw["id"]] = raw
          end
          raise InvalidLibrary, "no cultures loaded from #{LIBRARY_DIR}" if @cultures.empty?
        end

        def validate!(raw, path)
          %w[id weight given_male given_female family
             place_prefix place_suffix kingdom_suffix].each do |f|
            raise InvalidLibrary, "#{path}: missing #{f}" if raw[f].nil?
          end
          raise InvalidLibrary, "#{path}: id must be non-empty String"            unless raw["id"].is_a?(String) && !raw["id"].empty?
          raise InvalidLibrary, "#{path}: weight must be positive Integer"        unless raw["weight"].is_a?(Integer) && raw["weight"] > 0
          %w[given_male given_female].each do |pool|
            unless raw[pool].is_a?(Array) && raw[pool].any? && raw[pool].all? { |x| x.is_a?(String) && !x.empty? }
              raise InvalidLibrary, "#{path}: #{pool} must be non-empty Array of non-empty Strings"
            end
          end
          overlap = raw["given_male"] & raw["given_female"]
          raise InvalidLibrary, "#{path}: given_male/given_female overlap (#{overlap.join(', ')}) — pools must be disjoint" if overlap.any?
          unless raw["family"].is_a?(Array) && raw["family"].all? { |x| x.is_a?(String) }
            raise InvalidLibrary, "#{path}: family must be Array of Strings (empty allowed)"
          end
          # Place morphology pools (mechanical location/kingdom naming).
          %w[place_prefix place_suffix kingdom_suffix].each do |pool|
            unless raw[pool].is_a?(Array) && raw[pool].any? && raw[pool].all? { |x| x.is_a?(String) && !x.empty? }
              raise InvalidLibrary, "#{path}: #{pool} must be non-empty Array of non-empty Strings"
            end
          end
          # place_word is the optional space-separated variety form ("Oak Ridge").
          unless raw["place_word"].nil? || (raw["place_word"].is_a?(Array) && raw["place_word"].all? { |x| x.is_a?(String) })
            raise InvalidLibrary, "#{path}: place_word must be Array of Strings (optional)"
          end
        end
      end
    end
  end
end
