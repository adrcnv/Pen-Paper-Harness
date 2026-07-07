require "yaml"

module Harness
  module Scenarios
    # Weighted scenario picker backed by a YAML table.
    #
    # The "structurally enforced fun distribution" lever — instead of asking the
    # LLM to "be more interesting sometimes," we roll dice in code and route to
    # a scenario directive that the LLM then renders. Most rolls hit
    # "nothing_interesting" (a no-op directive) — interesting things stay rare
    # by construction, not by prompt-tuning hope.
    #
    # YAML format (one entry per scenario):
    #
    #   - id: founding_betrayal
    #     weight: 3
    #     requires: { biome: lowland }   # optional; entry only eligible when context matches
    #     prompt_seed: |
    #       SCENARIO: ...directive text the LLM will see in INPUT...
    #
    # Roll: filter by `requires` against `context`, sum eligible weights, pick a
    # cumulative slot. Always returns SOMETHING — the table must contain at
    # least one entry that's universally eligible (typically the "nothing"
    # entry with no requires).
    module Roller
      Result = Struct.new(:id, :prompt_seed, keyword_init: true)

      class TableMissing  < StandardError; end
      class NoEligibleRow < StandardError; end

      TABLES_DIR = Rails.root.join("lib/harness/scenarios/tables")

      def self.roll(table:, context: {}, rng: Random.new)
        rows = load(table)
        eligible = rows.select { |r| eligible?(r, context) }
        raise NoEligibleRow, "no eligible scenarios in table=#{table} for context=#{context.inspect}" if eligible.empty?

        total  = eligible.sum { |r| r["weight"] }
        target = rng.rand(total) + 1  # 1..total

        cum = 0
        eligible.each do |row|
          cum += row["weight"]
          return Result.new(id: row["id"], prompt_seed: row["prompt_seed"]) if target <= cum
        end

        # Unreachable; defensive.
        last = eligible.last
        Result.new(id: last["id"], prompt_seed: last["prompt_seed"])
      end

      def self.load(table)
        @cache ||= {}
        @cache[table] ||= load_uncached(table)
      end

      def self.reload!
        @cache = {}
      end

      def self.load_uncached(table)
        path = TABLES_DIR.join("#{table}.yml")
        raise TableMissing, "scenario table not found: #{path}" unless path.exist?

        rows = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        validate!(rows, table)
        rows
      end

      ALLOWED_ROW_KEYS = %w[id weight requires prompt_seed].freeze

      def self.validate!(rows, table)
        raise TableMissing, "scenario table empty: #{table}" if rows.nil? || rows.empty?
        rows.each_with_index do |row, i|
          raise TableMissing, "scenario table=#{table} row=#{i} missing id"     unless row["id"].is_a?(String)
          # weight=0 is allowed: entry kept around but never selected (handy for
          # disabling a scenario without deleting it). Negative is still invalid.
          raise TableMissing, "scenario table=#{table} row=#{i} missing weight" unless row["weight"].is_a?(Integer) && row["weight"] >= 0
          # Unknown keys are almost certainly a mis-authored gate (e.g. a bare
          # `gender: female` instead of `requires: { gender: female }`), which
          # would otherwise be silently ignored and leave the row open to all.
          unknown = row.keys - ALLOWED_ROW_KEYS
          raise TableMissing, "scenario table=#{table} row=#{row["id"]} unknown key(s): #{unknown.join(", ")} — gating conditions go under requires:" if unknown.any?
        end
        ids = rows.map { |r| r["id"] }
        dup = ids.detect { |id| ids.count(id) > 1 }
        raise TableMissing, "scenario table=#{table} has duplicate id=#{dup}" if dup
      end

      def self.eligible?(row, context)
        req = row["requires"]
        return true if req.nil? || req.empty?
        req.all? { |k, v| context[k.to_sym] == v || context[k.to_s] == v }
      end
    end
  end
end
