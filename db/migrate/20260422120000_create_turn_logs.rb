class CreateTurnLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :turn_logs do |t|
      t.integer :turn_number, null: false
      t.integer :location_id
      t.text    :input
      t.text    :phase1_prompt
      t.text    :phase1_tool_calls  # JSON: [{name, args, result}, ...]
      t.text    :phase2_prompt
      t.text    :narration
      t.text    :error
      t.timestamps
    end
    add_index :turn_logs, :turn_number
    add_index :turn_logs, :location_id
  end
end
