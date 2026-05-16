require "json"

module Harness
  module Scene
    module CharacterCatchUp
      # Validates the LLM's output, returns array of {character_id, events}.
      # Drops events outside the lookback window or with bad shape — they are
      # not committed. Raises InvalidOutput on JSON parse error or missing
      # top-level structure (caller decides whether to retry).
      module Hydrator
        class InvalidOutput < StandardError
          attr_reader :errors
          def initialize(errors)
            @errors = errors
            super(errors.join("; "))
          end
        end

        MAX_EVENTS_PER_CHARACTER = 1

        def self.hydrate(llm_output:, current_game_time:, lookback_window:, valid_character_ids:)
          parsed = parse(llm_output)
          chars = parsed["characters"]
          raise InvalidOutput, [ "missing 'characters' array" ] unless chars.is_a?(Array)

          floor = current_game_time - lookback_window
          ceil  = current_game_time

          out = []
          chars.each_with_index do |c, i|
            next unless c.is_a?(Hash)
            cid = c["character_id"]
            unless cid.is_a?(Integer) && valid_character_ids.include?(cid)
              # Silent drop — character not in input scope; not a fatal error.
              next
            end

            # Filter to valid events first, THEN cap. At MAX=1, capping raw
            # LLM output before validation would let an out-of-window event in
            # slot 0 swallow a valid event that came after it.
            events = []
            (c["events"] || []).each do |e|
              next unless e.is_a?(Hash)
              gt = e["game_time"]
              next unless gt.is_a?(Integer) && gt >= floor && gt <= ceil
              summary   = (e["summary"]   || "").to_s
              narrative = (e["narrative"] || "").to_s
              role      = (e["role"]      || "").to_s
              next if summary.strip.empty? || role.strip.empty?
              events << {
                "game_time" => gt,
                "summary"   => summary,
                "narrative" => narrative,
                "role"      => role
              }
            end
            events = events.first(MAX_EVENTS_PER_CHARACTER)

            out << { "character_id" => cid, "events" => events } unless events.empty?
          end

          out
        end

        def self.parse(raw)
          JSON.parse(raw)
        rescue JSON::ParserError => e
          raise InvalidOutput, [ "invalid JSON: #{e.message}" ]
        end
      end
    end
  end
end
