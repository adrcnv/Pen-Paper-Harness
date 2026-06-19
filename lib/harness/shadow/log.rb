require "json"
require "fileutils"

module Harness
  module Shadow
    # Append-only JSONL sink for shadow-planner records. One line per turn.
    # Lives under log/ (gitignored). Read offline after a session to compare
    # what the planner WOULD have done against what the agentic loop ACTUALLY
    # did — and, when two tiers are configured, to diff the small model's plan
    # against the big model's.
    #
    # Pure logging. Never raises into the turn: append swallows IO errors with
    # a warning. The whole point is zero risk to the live playthrough.
    module Log
      DEFAULT_PATH = Rails.root.join("log/shadow_planner.jsonl")

      def self.append(record, path: DEFAULT_PATH, logger: Rails.logger)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "a") { |f| f.puts(JSON.generate(record)) }
      rescue StandardError => e
        logger.warn { "[Shadow::Log] write failed: #{e.class}: #{e.message}" }
      end

      # Build the per-turn record from the planner result + the live turn's
      # transcript (so the agentic actual sits next to the planner's plan).
      def self.record_for(turn_number:, planner_result:, transcript:)
        {
          "turn"    => turn_number,
          "time"    => Time.now.utc.iso8601,
          "input"   => planner_result["input"],
          "world"   => planner_result["world"],
          "planner" => planner_result["plans"],
          "agentic" => agentic_summary(transcript)
        }
      end

      # What the live agentic loop actually committed this turn, in the same
      # ordered shape the planner data uses. The key comparison axes:
      #   - tool_sequence: ordered tool names (the "shape" of the turn)
      #   - tool_count:    total calls (silent=0, runaway=15-20)
      #   - silent:        emitted zero tools
      def self.agentic_summary(transcript)
        calls = transcript.tool_calls || []
        names = calls.map { |c| c["name"] }
        {
          "tool_count"    => names.size,
          "silent"        => names.empty?,
          "tool_sequence" => names,
          "error"         => transcript.error
        }
      end
    end
  end
end
