class CreateBeliefs < ActiveRecord::Migration[8.1]
  def change
    create_table :beliefs do |t|
      t.references :holder, null: false, foreign_key: { to_table: :entities }
      t.text    :claim, null: false
      t.float   :confidence, null: false, default: 1.0
      t.references :source_event, foreign_key: { to_table: :events }
      t.integer :formed_at

      t.timestamps
    end
  end
end
