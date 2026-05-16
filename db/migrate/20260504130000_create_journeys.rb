class CreateJourneys < ActiveRecord::Migration[8.0]
  # Singleton-ish per player — only one active journey at a time. Tracks the
  # cursor between top-level locations (any coords → any coords; the Path
  # graph is gone). The cursor lives in the row, not on Player; Player's
  # location_id stays at the most-recent stop (origin until first
  # encounter/snap/arrival, then whatever stop was set).
  def change
    create_table :journeys do |t|
      t.references :destination, null: false, foreign_key: { to_table: :locations }
      t.float   :origin_x,             null: false
      t.float   :origin_y,             null: false
      t.float   :cursor_x,             null: false
      t.float   :cursor_y,             null: false
      t.integer :started_at_game_time, null: false, default: 0
      t.integer :elapsed_minutes,      null: false, default: 0
      t.timestamps
    end
  end
end
