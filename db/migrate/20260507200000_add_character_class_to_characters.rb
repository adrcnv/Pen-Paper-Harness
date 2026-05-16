class AddCharacterClassToCharacters < ActiveRecord::Migration[8.0]
  def change
    add_column :characters, :character_class, :string, null: false, default: "commoner"
  end
end
