class AddIsKingdomToEntities < ActiveRecord::Migration[8.1]
  def change
    add_column :entities, :is_kingdom, :boolean, null: false, default: false
    add_index  :entities, :is_kingdom
  end
end
