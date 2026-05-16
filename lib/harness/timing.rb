module Harness
  # Per-call wall-clock timing for LLM adapters. Disabled by default;
  # bin/play enables it under --log-level=debug. Each call gets a tag
  # (adapter name + current CostTracker subsystem) and a duration in ms.
  #
  # In-memory turn ledger only — wipes at Turn::Loop.run_turn start, no
  # session-level retention. /debug elapsed prints the most recent turn's
  # breakdown.
  module Timing
    TURN_KEY = :harness_timing_turn_ledger

    class << self
      def enabled?
        @enabled == true
      end

      def enable!  ; @enabled = true  ; end
      def disable! ; @enabled = false ; end

      # Wraps a block, measures wall-clock duration, records on completion.
      # Returns the block's value.
      def measure(adapter:, logger: nil)
        return yield unless enabled?
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        if enabled?
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
          subsystem = ::Harness::CostTracker.current_subsystem
          turn_ledger << { adapter: adapter, subsystem: subsystem, duration_ms: ms }
          (logger || ::Rails.logger)&.debug { "[Timing] adapter=#{adapter} subsystem=#{subsystem} ms=#{ms}" }
        end
      end

      def reset_turn!
        Thread.current[TURN_KEY] = []
      end

      def turn_ledger
        Thread.current[TURN_KEY] ||= []
      end

      def turn_total_ms
        turn_ledger.sum { |e| e[:duration_ms] }
      end
    end
  end
end
