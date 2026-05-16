class AddLevelToCharacters < ActiveRecord::Migration[8.0]
  def change
    add_column :characters, :level, :integer, null: false, default: 1
  end
end
