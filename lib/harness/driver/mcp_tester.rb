require "json"
require "fileutils"

module Harness
  module Driver
    # Server-side half of the MCP playtester: one run, seven verbs, one run
    # folder (snapshots-N/, flags.jsonl, report.json). The tester is a player
    # with a notepad — verbs return only what a player would see. Evidence
    # for a flag (receipts, transcript tail, log tail, snapshot ref, seed) is
    # bundled HERE so the tester spots problems without diagnosing them.
    class McpTester
      RECEIPTS_KEPT   = 3
      TRANSCRIPT_KEPT = 5
      LOG_TAIL_BYTES  = 32_768

      attr_reader :run_dir, :session

      # session_factory: ->(seed, snapshot_dir) { booted Session } — the
      # default generates a fresh world; tests inject a stub-backed session.
      def initialize(run_dir:, logger: Rails.logger, log_path: nil, session_factory: nil)
        @run_dir         = run_dir.to_s
        @logger          = logger
        @log_path        = log_path
        @session_factory = session_factory || method(:build_session)
        @starts          = 0
        @flag_count      = 0
        reset_run_state!
        FileUtils.mkdir_p(@run_dir)
      end

      # Fresh world, fresh session. Callable again mid-run (a restart);
      # snapshots land in a new snapshots-N folder, flags keep accumulating.
      def start_scenario(seed: nil)
        @starts += 1
        reset_run_state!
        seed ||= Random.new_seed % (2**31)
        @session = @session_factory.call(seed, File.join(@run_dir, "snapshots-#{@starts}"))
        { "status" => "world ready", "seed" => seed,
          "location" => @session.player_location&.name, "game_time" => @session.game_time,
          "opening" => @session.opening }.compact
      end

      def play_turn(input:)
        ensure_started!
        result = @session.play(input)
        remember(input, result)
        player_view(result)
      end

      # No cause field by design: the tester reports what looked wrong from
      # the chair; the server attaches everything a diagnosis will need.
      def flag(observation:)
        ensure_started!
        entry = {
          "observation" => observation,
          "at_turn"     => @session.turn_number,
          "seed"        => @session.seed,
          "snapshot"    => "snapshots-#{@starts}/turn_#{@session.turn_number}.sqlite",
          "wiring"      => ::Harness::Debug::Replay.wiring_stamp,
          "transcript"  => @transcript.dup,
          "receipts"    => @receipts.dup,
          "log_tail"    => log_tail
        }
        File.open(File.join(@run_dir, "flags.jsonl"), "a") { |f| f.puts(JSON.generate(entry)) }
        @flag_count += 1
        { "status" => "flagged", "flags_so_far" => @flag_count }
      end

      def checkpoint(label:)
        ensure_started!
        @checkpoints[label] = @session.turn_number
        { "status" => "checkpoint saved", "label" => label, "turn" => @session.turn_number }
      end

      def rewind(label:)
        ensure_started!
        turn = @checkpoints.fetch(label) { raise ArgumentError, "no checkpoint named #{label.inspect}" }
        @session.rewind_to!(turn)
        forget_after(turn)
        { "status" => "rewound", "label" => label, "turn" => turn,
          "location" => @session.player_location&.name, "game_time" => @session.game_time }
      end

      # Reproduce-once: rewind one turn and re-run it verbatim.
      def retry_turn
        ensure_started!
        result = @session.retry_last!
        remember(result.dig("receipt", "input"), result)
        player_view(result)
      end

      def end_scenario(recount:, succeeded:)
        report = {
          "recount"   => recount,
          "succeeded" => succeeded,
          "turns"     => @session&.turn_number,
          "flags"     => @flag_count,
          "seed"      => @session&.seed,
          "ended_at"  => Time.now.utc.iso8601
        }
        File.write(File.join(@run_dir, "report.json"), JSON.pretty_generate(report))
        { "status" => "recorded", "run_dir" => @run_dir, "flags" => @flag_count }
      end

      private

      def ensure_started!
        raise "no scenario running — call start_scenario first" unless @session
      end

      def reset_run_state!
        @checkpoints = {}
        @transcript  = []
        @receipts    = []
      end

      def player_view(result)
        { "turn"      => @session.turn_number,
          "narration" => result["narration"],
          "notice"    => result["notice"],
          "halted"    => result["halted"],
          "game_time" => result["game_time"],
          "location"  => result["location"] }
      end

      # Ring buffers behind flag evidence. Dropping entries at >= this turn
      # first keeps a retried turn from appearing twice.
      def remember(input, result)
        turn = @session.turn_number
        forget_after(turn - 1)
        @transcript << { "turn" => turn, "input" => input,
                         "narration" => result["narration"], "notice" => result["notice"] }
        @transcript.shift while @transcript.size > TRANSCRIPT_KEPT
        if (receipt = result["receipt"])
          @receipts << receipt.merge("turn" => turn)
          @receipts.shift while @receipts.size > RECEIPTS_KEPT
        end
      end

      def forget_after(turn)
        @transcript.reject! { |e| e["turn"] > turn }
        @receipts.reject!   { |e| e["turn"] > turn }
      end

      def log_tail
        return nil unless @log_path && File.exist?(@log_path)
        size = File.size(@log_path)
        File.open(@log_path) do |f|
          f.seek([ size - LOG_TAIL_BYTES, 0 ].max)
          f.read
        end
      rescue StandardError
        nil
      end

      def build_session(seed, snapshot_dir)
        session = Session.new(seed: seed, snapshot_dir: snapshot_dir, logger: @logger)
        session.new_world!
        session
      end
    end
  end
end
