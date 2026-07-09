class CreateSessionStates < ActiveRecord::Migration[8.0]
  def change
    # Singleton row: the live session's cross-turn in-memory state, flushed at
    # every turn boundary so (a) a quit/crash can resume the scene instead of
    # losing the conversation buffer, and (b) the per-turn DB snapshot is a
    # COMPLETE save-state (the replay rig's rewind restores scene + history
    # from this row). git_sha / prompt_hash stamp the wiring the row was
    # written under — the staleness tripwire for cross-version restores.
    create_table :session_states do |t|
      t.integer :location_id
      t.text    :scene        # Scene::Serializer.dump of the active scene (JSON), nil between scenes
      t.text    :history      # context.history (JSON array of {input, narration})
      t.integer :game_time
      t.string  :git_sha
      t.string  :prompt_hash
      t.timestamps
    end

    add_column :turn_logs, :llm_seed, :integer
  end
end
