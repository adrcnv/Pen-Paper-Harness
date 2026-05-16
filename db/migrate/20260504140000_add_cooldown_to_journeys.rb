class AddCooldownToJourneys < ActiveRecord::Migration[8.0]
  def change
    add_column :journeys, :cooldown_until_game_time, :integer, null: false, default: 0
  end
end
