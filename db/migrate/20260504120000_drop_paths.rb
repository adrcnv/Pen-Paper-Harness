class DropPaths < ActiveRecord::Migration[8.0]
  def up
    drop_table :paths
  end

  def down
    create_table :paths do |t|
      t.references :from, null: false, foreign_key: { to_table: :locations }
      t.references :to,   null: false, foreign_key: { to_table: :locations }
      t.integer    :cost_minutes, null: false, default: 1
      t.string     :description
      t.timestamps
    end
  end
end
