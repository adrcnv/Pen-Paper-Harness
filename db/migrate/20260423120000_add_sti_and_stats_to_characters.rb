class AddStiAndStatsToCharacters < ActiveRecord::Migration[8.1]
  def up
    add_column :characters, :type, :string
    add_column :characters, :strength,     :integer
    add_column :characters, :dexterity,    :integer
    add_column :characters, :constitution, :integer
    add_column :characters, :intelligence, :integer
    add_column :characters, :wisdom,       :integer
    add_column :characters, :charisma,     :integer

    add_index :characters, :type

    # Any pre-STI rows become Npcs; the Player row is introduced by callers.
    execute "UPDATE characters SET type = 'Npc' WHERE type IS NULL"
  end

  def down
    remove_column :characters, :type
    remove_column :characters, :strength
    remove_column :characters, :dexterity
    remove_column :characters, :constitution
    remove_column :characters, :intelligence
    remove_column :characters, :wisdom
    remove_column :characters, :charisma
  end
end
