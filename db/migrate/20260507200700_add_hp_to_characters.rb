class AddHpToCharacters < ActiveRecord::Migration[8.0]
  def change
    add_column :characters, :max_hp,     :integer, null: false, default: 0
    add_column :characters, :current_hp, :integer, null: false, default: 0
  end
end
