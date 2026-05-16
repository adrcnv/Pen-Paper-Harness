module Harness
  # Per-turn / per-session token cost tracking. Hooked from LLM adapters at
  # response time; tagged by subsystem via thread-local stack (materializers
  # wrap their work in `in_subsystem(:belief_materializer) { ... }`).
  #
  # Pricing in USD per million tokens. Cached input is ~10% of normal input
  # (Anthropic's prompt-cache discount); cache writes cost ~25% extra on the
  # first write. Output is the most expensive component for short-output
  # calls (narration), input dominates for long-context calls (materializers
  # with full event history).
  #
  # Three call surfaces:
  #   - record(model:, usage:)       — adapter calls this after each response
  #   - in_subsystem(name) { ... }   — wrap LLM calls so they get tagged
  #   - reset_turn! / turn_breakdown — turn loop resets at start, bin/play
  #                                     reads breakdown after each turn
  module CostTracker
    PRICING = {
      "claude-haiku-4-5-20251001"  => { input: 1.00, cached_input: 0.10, cache_write: 1.25, output: 5.00 },
      "claude-sonnet-4-5-20251001" => { input: 3.00, cached_input: 0.30, cache_write: 3.75, output: 15.00 },
      "claude-opus-4-1-20250805"   => { input: 15.00, cached_input: 1.50, cache_write: 18.75, output: 75.00 }
    }.freeze
    DEFAULT_PRICING = { input: 3.00, cached_input: 0.30, cache_write: 3.75, output: 15.00 }.freeze

    SUBSYSTEM_KEY = :harness_cost_subsystem_stack
    TURN_KEY      = :harness_cost_turn_ledger

    class << self
      # Wrap a block so any LLM calls that fire underneath get tagged with
      # this subsystem. Stack-based — nested wraps inherit the innermost tag.
      def in_subsystem(name)
        stack.push(name.to_sym)
        yield
      ensure
        stack.pop
      end

      def current_subsystem
        stack.last || :unknown
      end

      def record(model:, usage:)
        return unless usage.is_a?(Hash)
        cost = compute_cost(model, usage)
        entry = {
          subsystem:    current_subsystem,
          model:        model,
          input:        (usage["input_tokens"]                || 0).to_i,
          cached_read:  (usage["cache_read_input_tokens"]     || 0).to_i,
          cache_write:  (usage["cache_creation_input_tokens"] || 0).to_i,
          output:       (usage["output_tokens"]               || 0).to_i,
          cost:         cost
        }
        turn_ledger << entry
        session_ledger << entry
        entry
      end

      def reset_turn!
        Thread.current[TURN_KEY] = []
      end

      def turn_ledger
        Thread.current[TURN_KEY] ||= []
      end

      def session_ledger
        @session_ledger ||= []
      end

      def reset_session!
        @session_ledger = []
        reset_turn!
      end

      def turn_total
        turn_ledger.sum { |e| e[:cost] }
      end

      def session_total
        session_ledger.sum { |e| e[:cost] }
      end

      # { subsystem => { calls:, cost:, input:, cached_read:, cache_write:, output: } }
      def turn_breakdown
        breakdown_for(turn_ledger)
      end

      def session_breakdown
        breakdown_for(session_ledger)
      end

      private

      def stack
        Thread.current[SUBSYSTEM_KEY] ||= []
      end

      def compute_cost(model, usage)
        rates       = PRICING[model] || DEFAULT_PRICING
        input       = (usage["input_tokens"]                || 0).to_i * rates[:input]
        cached_read = (usage["cache_read_input_tokens"]     || 0).to_i * rates[:cached_input]
        cache_write = (usage["cache_creation_input_tokens"] || 0).to_i * rates[:cache_write]
        output      = (usage["output_tokens"]               || 0).to_i * rates[:output]
        (input + cached_read + cache_write + output) / 1_000_000.0
      end

      def breakdown_for(ledger)
        ledger.group_by { |e| e[:subsystem] }.transform_values do |entries|
          {
            calls:       entries.size,
            cost:        entries.sum { |e| e[:cost] },
            input:       entries.sum { |e| e[:input] },
            cached_read: entries.sum { |e| e[:cached_read] },
            cache_write: entries.sum { |e| e[:cache_write] },
            output:      entries.sum { |e| e[:output] }
          }
        end
      end
    end
  end
end
