# Quest system killed (dead code — generation never survived the weak model's
# JSON, concept superseded by the hooks direction). Guarded so fresh DBs
# (which never ran the deleted create_quests migration) migrate cleanly.
class DropQuests < ActiveRecord::Migration[8.0]
  def up
    drop_table :quest_steps, if_exists: true
    drop_table :quests, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
