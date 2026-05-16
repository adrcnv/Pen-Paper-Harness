class AddAbilitiesToCharacters < ActiveRecord::Migration[8.1]
  def change
    # nil = not yet materialized; [] = materialized, has none; [...] = has these.
    # Stored as JSON text via ActiveRecord serialize.
    add_column :characters, :abilities, :text
  end
end
