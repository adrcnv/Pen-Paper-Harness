class AddXpToCharacters < ActiveRecord::Migration[8.0]
  def change
    add_column :characters, :xp, :integer, null: false, default: 0
  end
end
