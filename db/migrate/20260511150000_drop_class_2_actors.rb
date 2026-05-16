class DropClass2Actors < ActiveRecord::Migration[8.1]
  # Phase 2 of the post-3-lost-men architectural cleanup: every event
  # participant must be a real Character row. Class-2 (actor_name string)
  # participants are retired entirely.
  #
  # Backfill: for each unique actor_name in event_participants, create a
  # bare Character row with properties.dormant = true. The dormant flag
  # excludes them from present_characters / recent_actors until something
  # wakes them (Scene::Materializer at scene entry, an explicit relocation,
  # etc). Stats / abilities / HP stay at defaults — Hatchery doesn't run
  # in a migration. These rows become "full" class-4 the first time anyone
  # touches them post-migration; until then they're row-shaped placeholders.
  #
  # Location assignment: the actor_name's first event's location, or nil if
  # the actor only appeared in location-less events.
  #
  # Cross-location collisions: each unique (case-sensitive) actor_name maps
  # to ONE character. If two unrelated "Korr"s existed, they merge — same
  # policy the Materializer's class-2 promotion path used by default.
  #
  # PendingAppearance.actor_name: same backfill (look up the character we
  # just created, set actor_character_id). Drop column.

  def up
    backfill_event_participants
    backfill_pending_appearances

    remove_index  :event_participants, :actor_name
    remove_column :event_participants, :actor_name

    remove_column :pending_appearances, :actor_name
  end

  def down
    add_column :event_participants, :actor_name, :string
    add_index  :event_participants, :actor_name

    add_column :pending_appearances, :actor_name, :string

    # Down migration cannot reliably reverse the row creation (no marker
    # distinguishes migration-backfilled rows from genuinely-created ones).
    # Accept lossy down: schema flips back, rows stay. Restoring class-2
    # behavior on a downgraded DB would need a separate cleanup script.
  end

  private

  def backfill_event_participants
    eps = execute(<<~SQL).to_a
      SELECT DISTINCT actor_name FROM event_participants
      WHERE actor_name IS NOT NULL AND character_id IS NULL
    SQL
    return if eps.empty?

    say_with_time "Backfilling #{eps.size} unique actor_name(s) into class-4 dormant rows" do
      eps.each do |row|
        name = row["actor_name"]
        next if name.nil? || name.strip.empty?

        loc_row = execute(<<~SQL).to_a.first
          SELECT events.location_id
          FROM event_participants
          INNER JOIN events ON events.id = event_participants.event_id
          WHERE event_participants.actor_name = #{quote(name)}
            AND event_participants.character_id IS NULL
          ORDER BY events.game_time ASC, events.id ASC
          LIMIT 1
        SQL
        location_id = loc_row && loc_row["location_id"]

        existing = execute(<<~SQL).to_a.first
          SELECT id FROM characters WHERE name = #{quote(name)} LIMIT 1
        SQL

        char_id = if existing
          existing["id"]
        else
          properties_json = '{"dormant":true}'
          execute(<<~SQL)
            INSERT INTO characters (type, name, properties, location_id, level, character_class, current_hp, max_hp, coins, xp, created_at, updated_at)
            VALUES ('Npc', #{quote(name)}, #{quote(properties_json)}, #{location_id ? location_id.to_i : 'NULL'}, 1, 'commoner', 0, 0, 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          SQL
          execute("SELECT last_insert_rowid() AS id").to_a.first["id"]
        end

        execute(<<~SQL)
          UPDATE event_participants
          SET character_id = #{char_id.to_i}, actor_name = NULL
          WHERE actor_name = #{quote(name)} AND character_id IS NULL
        SQL
      end
    end
  end

  def backfill_pending_appearances
    pas = execute(<<~SQL).to_a
      SELECT id, actor_name FROM pending_appearances
      WHERE actor_name IS NOT NULL AND actor_character_id IS NULL
    SQL
    return if pas.empty?

    say_with_time "Linking #{pas.size} pending_appearance(s) actor_name to character rows" do
      pas.each do |row|
        name = row["actor_name"]
        next if name.nil? || name.strip.empty?

        char = execute("SELECT id FROM characters WHERE name = #{quote(name)} LIMIT 1").to_a.first
        next unless char

        execute(<<~SQL)
          UPDATE pending_appearances
          SET actor_character_id = #{char["id"].to_i}, actor_name = NULL
          WHERE id = #{row['id'].to_i}
        SQL
      end
    end
  end
end
