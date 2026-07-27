class AddDueTimeToObligations < ActiveRecord::Migration[8.0]
  def change
    # Absolute game-minute a due falls at, baked from the free-text `due` at
    # write time. Nil = unparseable (a condition-due, not schedulable).
    add_column :obligations, :due_time, :integer
  end
end
