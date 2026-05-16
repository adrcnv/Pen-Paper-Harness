class CreateEntities < ActiveRecord::Migration[8.1]
  def change
    create_table :entities do |t|
      t.string :role,    null: false
      t.string :subrole
      t.references :location, foreign_key: true
      t.json :properties, default: {}

      t.timestamps
    end

    add_index :entities, :role
    add_index :entities, :subrole
  end
end
