require "yaml"

module Harness
  module Abilities
    # Loads + parses the static ability library + class roster from YAML.
    # Cached after first load; reload! drops the cache (test infra).
    #
    # The library is hand-authored; nothing in here is LLM-generated. The
    # Assigner picks rows from it deterministically by class + min_level.
    module Library
      ABILITIES_PATH = Rails.root.join("lib/harness/abilities/library.yml")
      CLASSES_PATH   = Rails.root.join("lib/harness/abilities/classes.yml")

      ALLOWED_EFFECT_KINDS = %w[damage heal buff debuff control utility].freeze
      ALLOWED_RANGES       = %w[self close near far].freeze
      ALLOWED_AREAS        = %w[blast_small blast_large line_short cone self].freeze

      class << self
        def all
          @abilities ||= load_abilities
        end

        def find(id)
          by_id[id.to_s]
        end

        def for_class(class_id, max_level: nil)
          rows = all.select { |a| a["classes"].include?(class_id.to_s) }
          rows = rows.select { |a| a["min_level"] <= max_level } if max_level
          rows
        end

        def classes
          @classes ||= load_classes
        end

        def class_def(id)
          classes_by_id[id.to_s]
        end

        # Primary stat lookup for a character's class. Returns nil for
        # commoner (or unknown classes); resolve falls back to whatever
        # caller supplies in that case.
        def primary_stat(class_id)
          class_def(class_id)&.dig("primary_stat")
        end

        # Hit die size for a class (the integer N where the class rolls 1dN
        # per level for HP). Defaults to 6 if class is unknown.
        def hit_die(class_id)
          class_def(class_id)&.dig("hit_die") || 6
        end

        # Resolves which stat to use when a given character casts a given
        # ability. Resolution order:
        #   1. Ability has explicit stat: override — use it
        #   2. Character's class has a primary_stat — use it
        #   3. Walk the ability's classes array, find the first with a
        #      primary_stat — use it (handles commoner casting fighter
        #      abilities: commoner.primary_stat is nil but the ability's
        #      first class is fighter → STR)
        #   4. Final fallback: "strength"
        def stat_for_ability(ability:, character_class:)
          return ability["stat"] if ability["stat"]
          char_stat = primary_stat(character_class)
          return char_stat if char_stat
          ability["classes"].each do |c|
            s = primary_stat(c)
            return s if s
          end
          "strength"
        end

        def reload!
          @abilities    = nil
          @classes      = nil
          @abilities_by_id = nil
          @classes_by_id   = nil
        end

        private

        def by_id
          @abilities_by_id ||= all.each_with_object({}) { |a, h| h[a["id"]] = a }
        end

        def classes_by_id
          @classes_by_id ||= classes.each_with_object({}) { |c, h| h[c["id"]] = c }
        end

        def load_abilities
          rows = YAML.safe_load_file(ABILITIES_PATH, permitted_classes: [], aliases: false)
          raise "ability library is empty" if rows.nil? || rows.empty?
          rows.each { |r| validate!(r) }
          ids = rows.map { |r| r["id"] }
          dup = ids.detect { |i| ids.count(i) > 1 }
          raise "duplicate ability id: #{dup}" if dup
          rows
        end

        def load_classes
          rows = YAML.safe_load_file(CLASSES_PATH, permitted_classes: [], aliases: false)
          raise "class roster is empty" if rows.nil? || rows.empty?
          rows.each do |c|
            raise "class missing id: #{c.inspect}" unless c["id"].is_a?(String)
            raise "class missing name: #{c.inspect}" unless c["name"].is_a?(String)
            stat = c["primary_stat"]
            unless stat.nil? || ::Character::STATS.include?(stat)
              raise "class #{c['id'].inspect} primary_stat=#{stat.inspect} not in Character::STATS"
            end
            hit_die = c["hit_die"]
            unless hit_die.is_a?(Integer) && hit_die >= 4 && hit_die <= 12
              raise "class #{c['id'].inspect} hit_die=#{hit_die.inspect} must be int in [4, 12]"
            end
          end
          rows
        end

        def validate!(row)
          %w[id name description classes min_level effect_kind range uses_per_rest].each do |k|
            raise "ability #{row['id'].inspect} missing #{k}" unless row.key?(k)
          end
          unless row["classes"].is_a?(Array) && row["classes"].any?
            raise "ability #{row['id'].inspect} classes must be a non-empty array"
          end
          unless row["min_level"].is_a?(Integer) && row["min_level"] >= 1
            raise "ability #{row['id'].inspect} min_level must be int >= 1"
          end
          unless ALLOWED_EFFECT_KINDS.include?(row["effect_kind"])
            raise "ability #{row['id'].inspect} effect_kind=#{row['effect_kind'].inspect} not in #{ALLOWED_EFFECT_KINDS.inspect}"
          end
          unless ALLOWED_RANGES.include?(row["range"])
            raise "ability #{row['id'].inspect} range=#{row['range'].inspect} not in #{ALLOWED_RANGES.inspect}"
          end
          if row["area"] && !ALLOWED_AREAS.include?(row["area"])
            raise "ability #{row['id'].inspect} area=#{row['area'].inspect} not in #{ALLOWED_AREAS.inspect + [nil].inspect}"
          end
          unless row["uses_per_rest"].is_a?(Integer) && row["uses_per_rest"] >= 1
            raise "ability #{row['id'].inspect} uses_per_rest must be int >= 1"
          end
        end
      end
    end
  end
end
