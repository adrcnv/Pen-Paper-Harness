class AddMaterializedThroughToBeliefs < ActiveRecord::Migration[8.1]
  def up
    add_column :beliefs, :materialized_through_event_id, :integer
    add_column :beliefs, :retired_at, :datetime
    add_column :beliefs, :superseded_by_id, :integer
    add_index  :beliefs, :materialized_through_event_id
    add_index  :beliefs, :retired_at
    add_index  :beliefs, :superseded_by_id
  end

  def down
    remove_index  :beliefs, :superseded_by_id
    remove_index  :beliefs, :retired_at
    remove_index  :beliefs, :materialized_through_event_id
    remove_column :beliefs, :superseded_by_id
    remove_column :beliefs, :retired_at
    remove_column :beliefs, :materialized_through_event_id
  end
end
