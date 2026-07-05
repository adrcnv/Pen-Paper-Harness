class AddSupersedesToKnowledge < ActiveRecord::Migration[8.1]
  # Revision plumbing: when conversation ELABORATES a standing fact (adds a
  # name, a place, a cause), capture writes a merged replacement row and
  # retires the old one via `current: false`. This column is the audit link
  # from the replacement back to the row it superseded.
  def change
    add_column :knowledge, :supersedes_id, :integer
  end
end
