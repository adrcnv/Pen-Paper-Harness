require "fileutils"

module Harness
  module Debug
    # Named scenario shelf for the replay rig. A scenario is a folder under
    # snapshots/scenarios/<name>/ holding:
    #   db.sqlite        — VACUUM'd copy of the live DB at dump time (the
    #                      session_states buffer is inside — dump flushes first)
    #   turn_N.sqlite…   — the session's per-turn snapshots, shelved so
    #                      `/debug rewind` still has floors after a load
    # Loading PASTES db.sqlite over the live DB file (wholesale — no merge,
    # no information loss) and the session continues INSIDE the scenario
    # folder, so new turn snapshots append next to the shelved ones.
    module Scenarios
      class Error < StandardError; end

      NAME_PATTERN = /\A[\w-]+\z/

      module_function

      def root
        Rails.root.join("snapshots", "scenarios").to_s
      end

      def dir_for(name)
        File.join(root, name)
      end

      def list
        return [] unless Dir.exist?(root)
        Dir.children(root).select { |n| File.exist?(File.join(root, n, "db.sqlite")) }.sort
      end

      # Shelve the current state under a name. `flush` is a callable that
      # persists the in-memory session into the DB first (bin/play passes
      # loop_obj's baseline snapshot) — the dump must contain the buffer.
      def dump!(name:, snapshot_dir: nil, flush: nil)
        raise Error, "scenario name must be letters/digits/underscore/dash" unless name.to_s.match?(NAME_PATTERN)

        dir = dir_for(name)
        FileUtils.mkdir_p(dir)
        flush&.call

        db = File.join(dir, "db.sqlite")
        File.delete(db) if File.exist?(db)
        ActiveRecord::Base.connection.execute(
          "VACUUM INTO #{ActiveRecord::Base.connection.quote(db)}"
        )

        # Shelve this session's per-turn snapshots for rewind continuity —
        # skipped when dumping from a session without a snapshot dir, or when
        # dumping from inside the scenario folder itself (already there).
        if snapshot_dir && File.expand_path(snapshot_dir) != File.expand_path(dir)
          Dir.glob(File.join(snapshot_dir, "turn_*.sqlite")).each { |f| FileUtils.cp(f, dir) }
        end
        dir
      end

      # Remove a shelved scenario. Name-validated (no traversal) and only
      # ever removes a folder under the shelf root.
      def delete!(name:)
        raise Error, "scenario name must be letters/digits/underscore/dash" unless name.to_s.match?(NAME_PATTERN)
        dir = dir_for(name)
        raise Error, "no scenario #{name.inspect}" unless File.exist?(File.join(dir, "db.sqlite"))
        FileUtils.rm_rf(dir)
        dir
      end

      # Paste the scenario's DB over the live one (Replay handles the pool
      # disconnect + stale WAL/SHM). Boot-time only in practice — the caller
      # rebuilds context/player from the restored DB afterward.
      def load!(name:)
        db = File.join(dir_for(name), "db.sqlite")
        raise Error, "no scenario #{name.inspect} (#{db})" unless File.exist?(db)
        ::Harness::Debug::Replay.swap_db_file!(db)
        dir_for(name)
      end
    end
  end
end
