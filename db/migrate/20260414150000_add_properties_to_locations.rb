class AddPropertiesToLocations < ActiveRecord::Migration[8.1]
  def change
    add_column :locations, :properties, :json, default: {}
  end
end
