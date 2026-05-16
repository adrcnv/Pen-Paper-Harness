class AddCoinsToCharacters < ActiveRecord::Migration[8.0]
  def change
    add_column :characters, :coins, :integer, null: false, default: 0
  end
end
