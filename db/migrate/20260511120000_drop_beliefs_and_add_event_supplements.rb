class DropBeliefsAndAddEventSupplements < ActiveRecord::Migration[8.1]
  def up
    drop_table :beliefs

    add_column :events, :references_event_id, :integer
    add_index  :events, :references_event_id
  end

  def down
    remove_index  :events, :references_event_id
    remove_column :events, :references_event_id

    create_table :beliefs do |t|
      t.text     :claim, null: false
      t.float    :confidence, default: 1.0, null: false
      t.integer  :holder_id, null: false
      t.integer  :source_event_id
      t.integer  :formed_at
      t.integer  :materialized_through_event_id
      t.datetime :retired_at
      t.integer  :superseded_by_id
      t.timestamps
    end
    add_index :beliefs, :holder_id
    add_index :beliefs, :materialized_through_event_id
    add_index :beliefs, :retired_at
    add_index :beliefs, :source_event_id
    add_index :beliefs, :superseded_by_id
    add_foreign_key :beliefs, :characters, column: :holder_id
    add_foreign_key :beliefs, :events,     column: :source_event_id
  end
end
