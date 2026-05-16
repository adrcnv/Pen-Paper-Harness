class CreatePendingAppearances < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_appearances do |t|
      t.references :triggered_by_event, foreign_key: { to_table: :events }, index: true
      t.references :target_character,   null: false, foreign_key: { to_table: :characters }
      t.references :origin_character,   foreign_key: { to_table: :characters }
      t.references :origin_faction,     foreign_key: { to_table: :factions }
      t.references :actor_character,    foreign_key: { to_table: :characters }
      t.string  :actor_name
      t.text    :intent_text,           null: false
      t.references :anchor_location,    foreign_key: { to_table: :locations }
      t.string  :scope,                 null: false
      t.integer :earliest_at,           null: false
      t.integer :resolved_at
      t.timestamps
    end

    add_index :pending_appearances, [ :target_character_id, :resolved_at ],
              name: "idx_pending_appearances_target_unresolved"
    add_index :pending_appearances, [ :anchor_location_id, :resolved_at ],
              name: "idx_pending_appearances_anchor_unresolved"
  end
end
