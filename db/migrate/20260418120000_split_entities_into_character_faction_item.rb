class SplitEntitiesIntoCharacterFactionItem < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :locations,          column: :faction_id
    remove_foreign_key :beliefs,            column: :holder_id
    remove_foreign_key :event_participants, column: :entity_id

    create_table :characters do |t|
      t.string :name, null: false
      t.string :subrole
      t.references :location, foreign_key: true
      t.json   :properties, default: {}
      t.timestamps
    end
    add_index :characters, :subrole

    create_table :factions do |t|
      t.string  :name, null: false
      t.string  :subrole
      t.boolean :is_kingdom, null: false, default: false
      t.json    :properties, default: {}
      t.timestamps
    end
    add_index :factions, :subrole
    add_index :factions, :is_kingdom

    create_table :items do |t|
      t.string :name, null: false
      t.string :subrole
      t.references :location,  foreign_key: true
      t.references :character, foreign_key: true
      t.json   :properties, default: {}
      t.timestamps
    end
    add_index :items, :subrole

    add_foreign_key :locations, :factions,   column: :faction_id
    add_foreign_key :beliefs,   :characters, column: :holder_id

    remove_index :event_participants, name: "index_event_participants_on_entity_id_and_event_id"
    remove_index :event_participants, name: "index_event_participants_on_entity_id"
    rename_column :event_participants, :entity_id, :character_id
    change_column_null :event_participants, :character_id, true
    add_foreign_key :event_participants, :characters, column: :character_id
    add_index :event_participants, :character_id
    add_index :event_participants, [ :character_id, :event_id ]

    add_column :event_participants, :actor_name, :string
    add_index  :event_participants, :actor_name

    remove_foreign_key :events, column: :cause_id
    remove_index  :events, name: "index_events_on_cause_id"
    remove_column :events, :cause_id

    remove_index  :events, name: "index_events_on_event_type"
    remove_column :events, :event_type

    drop_table :entities
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
