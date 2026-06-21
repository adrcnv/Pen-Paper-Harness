class CreateWorlds < ActiveRecord::Migration[8.1]
  # Singleton metadata for the generated world. The geography is deterministic
  # from `seed` + `size` + `sea_level`, so those three reconstruct everything;
  # `rivers` caches the carved polylines (the one precomputed artifact) so the
  # downhill walk needn't re-run on every load and a later tweak to the carving
  # algorithm can't silently reshape an existing world. Fixes the long-flagged
  # "worldgen seed not persisted" open problem — /map can now redraw the
  # terrain backdrop, and runtime can sample terrain at any point.
  def change
    create_table :worlds do |t|
      t.integer :seed
      t.float   :size
      t.float   :sea_level
      t.integer :river_count
      t.json    :rivers, default: []
      t.timestamps
    end
  end
end
