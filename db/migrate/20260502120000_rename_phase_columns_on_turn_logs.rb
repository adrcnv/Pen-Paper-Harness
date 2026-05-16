class RenamePhaseColumnsOnTurnLogs < ActiveRecord::Migration[8.0]
  def change
    rename_column :turn_logs, :phase1_prompt,     :reasoning_prompt
    rename_column :turn_logs, :phase1_tool_calls, :reasoning_tool_calls
    rename_column :turn_logs, :phase2_prompt,     :narration_prompt
  end
end
