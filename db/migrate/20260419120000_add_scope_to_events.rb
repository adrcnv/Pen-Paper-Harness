class AddScopeToEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :events, :scope, :string, null: false, default: "personal"
    add_index  :events, :scope
  end

  def down
    remove_index  :events, :scope
    remove_column :events, :scope
  end
end
