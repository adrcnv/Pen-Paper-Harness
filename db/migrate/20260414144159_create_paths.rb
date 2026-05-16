class CreatePaths < ActiveRecord::Migration[8.1]
  def change
    create_table :paths do |t|
      t.references :from, null: false, foreign_key: { to_table: :locations }
      t.references :to,   null: false, foreign_key: { to_table: :locations }
      t.integer :cost_minutes, null: false, default: 0
      t.string  :description

      t.timestamps
    end
  end
end
