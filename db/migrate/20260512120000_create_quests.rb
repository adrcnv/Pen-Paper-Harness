class CreateQuests < ActiveRecord::Migration[8.1]
  # Wholesale-authored quest layer. Each Quest carries an ordered list of
  # QuestStep rows; the engine checks structural fulfillment at end-of-turn
  # via Harness::Quest::FulfillmentCheck. The LLM never marks steps fulfilled.
  #
  # See QUESTS_DESIGN.md for the full design.

  def change
    create_table :quests do |t|
      t.string  :name,               null: false
      t.text    :summary,             null: false
      t.string  :archetype_id,        null: false  # matches a YAML id
      t.string  :state,               null: false, default: "offered"
      t.integer :giver_character_id,  null: false
      t.integer :city_location_id,    null: false  # top-level city this quest is anchored to
      t.integer :created_event_id                  # backward kickoff event (nullable; set after commit)
      t.integer :resolved_event_id                 # event marking completion (nullable)
      t.timestamps
    end

    add_index :quests, :state
    add_index :quests, :giver_character_id
    add_index :quests, :city_location_id
    add_index :quests, :archetype_id

    add_foreign_key :quests, :characters, column: :giver_character_id
    add_foreign_key :quests, :locations,  column: :city_location_id
    add_foreign_key :quests, :events,     column: :created_event_id
    add_foreign_key :quests, :events,     column: :resolved_event_id

    create_table :quest_steps do |t|
      t.integer :quest_id,             null: false
      t.integer :position,             null: false  # linear order within the quest
      t.text    :description,           null: false  # what the player sees in /quests N
      t.string  :state,                 null: false, default: "pending"
      t.string  :fulfillment_kind,      null: false  # information|item_in_inventory|character_dead|character_at_location

      t.integer :target_character_id  # informant for `information`; target for `character_dead`/`character_at_location`
      t.integer :target_item_id       # `item_in_inventory`
      t.integer :target_location_id   # `character_at_location`

      t.integer :opened_at_game_time    # set when state → active
      t.integer :fulfilled_at_game_time # set when state → fulfilled
      t.json    :related_event_ids, default: []  # narrative context only; NOT used for fulfillment

      t.timestamps
    end

    add_index :quest_steps, :quest_id
    add_index :quest_steps, [ :quest_id, :position ], unique: true
    add_index :quest_steps, :state
    add_index :quest_steps, :target_character_id
    add_index :quest_steps, :target_item_id
    add_index :quest_steps, :target_location_id

    add_foreign_key :quest_steps, :quests
    add_foreign_key :quest_steps, :characters, column: :target_character_id
    add_foreign_key :quest_steps, :items,      column: :target_item_id
    add_foreign_key :quest_steps, :locations,  column: :target_location_id
  end
end
