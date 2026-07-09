require "rails_helper"
require "tmpdir"

RSpec.describe Harness::Debug::Scenarios do
  it "rejects names that would escape the shelf" do
    expect {
      described_class.dump!(name: "../evil")
    }.to raise_error(described_class::Error, /letters/)
  end

  it "load! refuses an unknown scenario before touching the DB file" do
    expect {
      described_class.load!(name: "does-not-exist")
    }.to raise_error(described_class::Error, /no scenario/)
  end

  it "delete! refuses unknown names and traversal shapes" do
    expect { described_class.delete!(name: "does-not-exist") }.to raise_error(described_class::Error, /no scenario/)
    expect { described_class.delete!(name: "../evil") }.to raise_error(described_class::Error, /letters/)
  end

  it "delete! removes a shelved scenario and it stops being listed" do
    name = "spec-tmp-delete-me"
    dir  = described_class.dir_for(name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "db.sqlite"), "stub")
    expect(described_class.list).to include(name)

    described_class.delete!(name: name)
    expect(Dir.exist?(dir)).to be(false)
    expect(described_class.list).not_to include(name)
  end

  # VACUUM INTO cannot run inside a transaction; this group opts out and
  # cleans up both the rows it makes and the shelf folder.
  describe "dump! + list" do
    self.use_transactional_tests = false

    let(:name) { "spec-tmp-scenario" }

    after do
      FileUtils.rm_rf(described_class.dir_for(name))
      [ SessionState, Character, Location ].each(&:delete_all)
    end

    it "shelves a db copy plus the session's turn snapshots, and lists the scenario" do
      Location.create!(name: "Shelfton")
      flushed = false

      Dir.mktmpdir do |session_dir|
        File.write(File.join(session_dir, "turn_7.sqlite"), "stub")
        dir = described_class.dump!(name: name, snapshot_dir: session_dir, flush: -> { flushed = true })

        expect(flushed).to be(true)
        expect(File.exist?(File.join(dir, "db.sqlite"))).to be(true)
        expect(File.exist?(File.join(dir, "turn_7.sqlite"))).to be(true)
        expect(described_class.list).to include(name)

        db = SQLite3::Database.new(File.join(dir, "db.sqlite"))
        count = db.execute("SELECT COUNT(*) FROM locations WHERE name = 'Shelfton'").first.first
        db.close
        expect(count).to eq(1)
      end
    end
  end
end
