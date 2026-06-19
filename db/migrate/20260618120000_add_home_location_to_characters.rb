class AddHomeLocationToCharacters < ActiveRecord::Migration[8.1]
  # home_location_id splits "where a character belongs" from location_id
  # ("where they are now"). Nullable on purpose: it's a SETTLEMENT-residence
  # concept — townsfolk, merchants, beggars (home = their city/sublocation)
  # carry one; hostiles and wilderness creatures do not (nil → old single-
  # location behavior, never drawn into settlement scenes, never evicted home).
  #
  # Backfill: existing NPCs standing in a settlement are assumed to live there
  # (home = current). NPCs in wilderness_leaf locations, and the player, stay
  # nil.
  def up
    add_column :characters, :home_location_id, :integer
    add_index  :characters, :home_location_id

    wilderness_ids = select_values(
      "SELECT id FROM locations WHERE json_extract(properties, '$.kind') = 'wilderness_leaf'"
    )
    exclusion = wilderness_ids.any? ? "AND location_id NOT IN (#{wilderness_ids.join(',')})" : ""
    execute(<<~SQL)
      UPDATE characters
         SET home_location_id = location_id
       WHERE type = 'Npc'
         AND location_id IS NOT NULL
         #{exclusion}
    SQL
  end

  def down
    remove_index  :characters, :home_location_id
    remove_column :characters, :home_location_id
  end
end
