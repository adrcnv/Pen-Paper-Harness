class CreateLocations < ActiveRecord::Migration[8.1]
  def change
    create_table :locations do |t|
      t.string :name, null: false
      t.text   :description
      t.references :parent, foreign_key: { to_table: :locations }

      t.timestamps
    end
  end
end
