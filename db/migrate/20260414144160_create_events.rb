class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.integer :game_time, null: false
      t.string  :event_type, null: false
      t.references :location, foreign_key: true
      t.references :cause,    foreign_key: { to_table: :events }
      t.json :details, default: {}

      t.timestamps
    end

    add_index :events, :game_time
    add_index :events, :event_type
  end
end
