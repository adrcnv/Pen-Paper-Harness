require "digest"
require "fileutils"

module Harness
  module Debug
    # The replay rig's rewind: restore the previous turn's snapshot over the
    # live DB and rehydrate the in-memory session from it — INERTLY (no
    # genesis, no catch-up, no draws; the scene buffer comes from the
    # session_states row inside the snapshot).
    #
    # Scope is deliberately narrow: ONE step back. Rewinding to turn N-1
    # destroys turn N (its snapshot file stays on disk, but the retried
    # timeline diverges — no branching, by design).
    #
    # Returns { input:, seed:, turn:, notices: [] } — the rewound turn's
    # original input and seed so `/debug retry` can re-run it verbatim —
    # or raises Error with a player-readable message.
    module Replay
      class Error < StandardError; end

      PROMPT_GLOB = "lib/harness/prompts/**/*.txt".freeze

      module_function

      # git SHA + hash of all prompt files: the wiring stamp written into
      # session_states (and thus every snapshot). Memoized per process.
      def wiring_stamp
        @wiring_stamp ||= {
          git_sha:     `git -C #{Rails.root} rev-parse --short HEAD 2>/dev/null`.strip.presence,
          prompt_hash: prompt_hash
        }
      rescue StandardError
        @wiring_stamp = { git_sha: nil, prompt_hash: nil }
      end

      def prompt_hash
        files = Dir.glob(Rails.root.join(PROMPT_GLOB)).sort
        Digest::MD5.hexdigest(files.map { |f| File.read(f) }.join("\0"))[0, 12]
      end

      # Rewind one turn. Captures the last turn's input+seed from the LIVE db
      # BEFORE the file swap (the snapshot predates that turn and doesn't
      # know it).
      def rewind!(context:, scene_manager:, snapshot_dir:, logger: Rails.logger)
        raise Error, "no snapshot dir configured" if snapshot_dir.to_s.empty?

        last = ::TurnLog.order(:turn_number).last
        raise Error, "no turns to rewind" unless last

        snap = File.join(snapshot_dir, "turn_#{last.turn_number - 1}.sqlite")
        raise Error, "no snapshot for turn #{last.turn_number - 1} (#{snap})" unless File.exist?(snap)

        input = last.input
        seed  = last.llm_seed
        turn  = last.turn_number

        swap_db_file!(snap)
        notices = stamp_drift_notices
        rehydrate!(context: context, scene_manager: scene_manager, logger: logger)

        logger.info { "[Debug::Replay] rewound to pre-turn-#{turn} state (#{snap})" }
        { input: input, seed: seed, turn: turn, notices: notices }
      end

      # Replace the live SQLite file with the snapshot. All pooled
      # connections must drop first; stale WAL/SHM siblings of the live db
      # are removed (the VACUUM'd snapshot is self-contained). ActiveRecord
      # re-establishes lazily on the next query.
      def swap_db_file!(snapshot_path)
        db_path = ActiveRecord::Base.connection_db_config.database
        raise Error, "cannot locate live DB file" unless db_path && File.exist?(db_path)

        ActiveRecord::Base.connection_pool.disconnect!
        FileUtils.cp(snapshot_path, db_path)
        [ "#{db_path}-wal", "#{db_path}-shm" ].each { |f| File.delete(f) if File.exist?(f) }
      end

      # Compare the restored row's wiring stamps against the live process.
      # Prompt drift is the NORMAL retry-with-fix flow — note it quietly.
      # Code drift is where missing-field surprises live — warn loudly.
      def stamp_drift_notices
        row = ::SessionState.current
        return [] unless row
        live = wiring_stamp
        notices = []
        if row.git_sha.present? && live[:git_sha].present? && row.git_sha != live[:git_sha]
          notices << "⚠ snapshot was written under commit #{row.git_sha}, you are on #{live[:git_sha]} — restored objects may not match current code"
        end
        if row.prompt_hash.present? && live[:prompt_hash].present? && row.prompt_hash != live[:prompt_hash]
          notices << "prompts changed since this snapshot — upstream buffer content was generated under the old prompts (normal for retry-with-fix)"
        end
        notices
      end

      # Rebuild the in-memory session from the restored DB: player location,
      # clock, history, and the scene buffer — via Manager#restore, never
      # via the enter chain.
      def rehydrate!(context:, scene_manager:, logger: Rails.logger)
        player = ::Player.first
        raise Error, "restored DB has no player row" unless player

        context.player_location = player.location
        context.clear_scene_dirty!

        row = ::SessionState.current
        context.game_time = row&.game_time || [ ::Event.maximum(:game_time) || 0, context.game_time.to_i ].max
        context.history.replace(Array(row&.history))

        active = row&.scene ? ::Harness::Scene::Serializer.load(row.scene) : nil
        scene_manager.restore(active)
        logger.debug { "[Debug::Replay] rehydrated: loc=#{player.location&.name} game_time=#{context.game_time} scene=#{active ? 'restored' : 'none'}" }
      end
    end
  end
end
