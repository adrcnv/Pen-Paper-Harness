class AddFactionToLocations < ActiveRecord::Migration[8.1]
  def change
    add_reference :locations, :faction,
      foreign_key: { to_table: :entities },
      null: true,
      index: true
  end
end
