class AddCoordinatesAndBiomeToLocations < ActiveRecord::Migration[8.1]
  # x, y, biome are populated only on parentless top-level Locations (cities,
  # wilderness sites). Sublocations leave them nil and inherit reach through
  # `parent_id` — the assembler's sibling-presence rule already does the right
  # thing without per-sublocation coordinates.
  def change
    add_column :locations, :x,     :float
    add_column :locations, :y,     :float
    add_column :locations, :biome, :string

    add_index  :locations, :biome
  end
end
