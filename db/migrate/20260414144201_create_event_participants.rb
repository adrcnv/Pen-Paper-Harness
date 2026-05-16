class CreateEventParticipants < ActiveRecord::Migration[8.1]
  def change
    create_table :event_participants do |t|
      t.references :event,  null: false, foreign_key: true
      t.references :entity, null: false, foreign_key: true
      t.string :role, null: false

      t.timestamps
    end

    add_index :event_participants, [:entity_id, :event_id]
  end
end
