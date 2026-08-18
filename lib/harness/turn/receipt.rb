module Harness
  module Turn
    # Per-turn flight recorder — the higher-resolution sibling of
    # /debug elapsed. One structured digest per turn: what ran, what tools
    # committed, what rows changed (constants only — free text is never
    # captured), how the clock moved, and the per-call timing ledger.
    # Consumers: /debug receipt, the scenario harness's assertions, and
    # flag evidence bundles. Disabled by default; bin/play and the headless
    # driver enable it. In-memory latest-turn only, like Timing.
    #
    # DB writes are captured via ApplicationRecord callbacks (create/update/
    # destroy). `update_column` writes bypass callbacks by design — those are
    # cache writes (embeddings) and deliberately invisible here.
    module Receipt
      TURN_KEY = :harness_receipt_turn_ledger

      # Longest string value the write ledger will carry verbatim. Anything
      # longer is prose, and prose is never receipt material.
      SCALAR_STRING_MAX = 60

      IGNORED_COLUMNS = %w[updated_at created_at embedding].freeze

      class << self
        def enabled?
          @enabled == true
        end

        def enable!  ; @enabled = true  ; end
        def disable! ; @enabled = false ; end

        def begin_turn!(game_time: nil)
          return unless enabled?
          Thread.current[TURN_KEY] = { writes: [], clock_before: game_time }
        end

        # ApplicationRecord callback target. No-ops unless a turn ledger is
        # open (writes outside a turn — worldgen, session setup — are not
        # turn events).
        def record_write(record, action)
          ledger = Thread.current[TURN_KEY]
          return unless enabled? && ledger

          entry = {
            "table"  => record.class.table_name,
            "id"     => record.id,
            "action" => action.to_s
          }
          entry["name"] = record.name if record.respond_to?(:name) && record.name.is_a?(::String)
          if action == :update
            changes = record.saved_changes.except(*IGNORED_COLUMNS)
            return if changes.empty?
            entry["changes"] = changes.to_h { |col, (old_v, new_v)|
              [ col, [ scalar(old_v), scalar(new_v) ] ]
            }
          end
          ledger[:writes] << entry
        rescue ::StandardError
          nil # the recorder must never break a write
        end

        # Assemble the digest. Called once at end of turn; stashes the result
        # for /debug receipt.
        def finalize!(transcript:, game_time: nil)
          ledger = Thread.current[TURN_KEY]
          return nil unless enabled? && ledger

          @last = {
            "input"       => transcript.input,
            "runners"     => Array(transcript.runners_ran),
            "tool_calls"  => Array(transcript.tool_calls).map { |tc| tool_call_entry(tc) },
            "db_writes"   => ledger[:writes],
            "clock"       => { "before" => ledger[:clock_before], "after" => game_time },
            "timings"     => ::Harness::Timing.turn_ledger.map(&:dup),
            "total_ms"    => ::Harness::Timing.turn_total_ms
          }
          @last["halted"]     = true                  if transcript.halted
          @last["unresolved"] = transcript.unresolved if transcript.unresolved
          @last["notice"]     = transcript.notice     if transcript.notice
          @last["error"]      = transcript.error      if transcript.error
          Thread.current[TURN_KEY] = nil
          @last
        end

        def last
          @last
        end

        private

        # Constants survive; prose is elided. Scalars (nil, numbers, bools)
        # and short strings pass through; anything else collapses to a
        # changed-marker.
        def scalar(v)
          case v
          when nil, ::Numeric, true, false then v
          when ::String then v.length <= SCALAR_STRING_MAX ? v : "…"
          else "…"
          end
        end

        def tool_call_entry(tc)
          name   = tc["name"] || tc[:name]
          args   = tc["args"] || tc[:args] || {}
          result = tc["result"] || tc[:result]
          entry = { "name" => name }
          entry["args"] = args.to_h { |k, v| [ k.to_s, scalar(v) ] } if args.respond_to?(:to_h) && args.any?
          if result.is_a?(::Hash) && (err = result["error"] || result[:error])
            entry["error"] = scalar(err) == "…" ? err.to_s[0, SCALAR_STRING_MAX] : err
          end
          entry
        end
      end
    end
  end
end
