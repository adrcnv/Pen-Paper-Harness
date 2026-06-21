class ChangeWorldsSeedToString < ActiveRecord::Migration[8.1]
  # Seeds come from Random.new_seed — a ~128-bit integer that overflows SQLite's
  # 8-byte integer column. Everything downstream only ever uses the seed via
  # `seed.to_i & 0xFFFFFFFF` (Noise, the geography rng), so storing it as a
  # string round-trips exactly without truncation and never overflows.
  def up
    change_column :worlds, :seed, :string
  end

  def down
    change_column :worlds, :seed, :integer
  end
end
