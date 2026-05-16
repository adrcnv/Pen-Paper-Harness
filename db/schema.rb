# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_12_120000) do
  create_table "characters", force: :cascade do |t|
    t.text "abilities"
    t.string "character_class", default: "commoner", null: false
    t.integer "charisma"
    t.integer "coins", default: 0, null: false
    t.integer "constitution"
    t.datetime "created_at", null: false
    t.integer "current_hp", default: 0, null: false
    t.integer "dexterity"
    t.integer "intelligence"
    t.integer "level", default: 1, null: false
    t.integer "location_id"
    t.integer "max_hp", default: 0, null: false
    t.string "name", null: false
    t.json "properties", default: {}
    t.integer "strength"
    t.string "subrole"
    t.string "type"
    t.datetime "updated_at", null: false
    t.integer "wisdom"
    t.integer "xp", default: 0, null: false
    t.index ["location_id"], name: "index_characters_on_location_id"
    t.index ["subrole"], name: "index_characters_on_subrole"
    t.index ["type"], name: "index_characters_on_type"
  end

  create_table "event_participants", force: :cascade do |t|
    t.integer "character_id"
    t.datetime "created_at", null: false
    t.integer "event_id", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["character_id", "event_id"], name: "index_event_participants_on_character_id_and_event_id"
    t.index ["character_id"], name: "index_event_participants_on_character_id"
    t.index ["event_id"], name: "index_event_participants_on_event_id"
  end

  create_table "events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "details", default: {}
    t.integer "game_time", null: false
    t.integer "location_id"
    t.integer "references_event_id"
    t.string "scope", default: "personal", null: false
    t.datetime "updated_at", null: false
    t.index ["game_time"], name: "index_events_on_game_time"
    t.index ["location_id"], name: "index_events_on_location_id"
    t.index ["references_event_id"], name: "index_events_on_references_event_id"
    t.index ["scope"], name: "index_events_on_scope"
  end

  create_table "factions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "is_kingdom", default: false, null: false
    t.string "name", null: false
    t.json "properties", default: {}
    t.string "subrole"
    t.datetime "updated_at", null: false
    t.index ["is_kingdom"], name: "index_factions_on_is_kingdom"
    t.index ["subrole"], name: "index_factions_on_subrole"
  end

  create_table "items", force: :cascade do |t|
    t.integer "character_id"
    t.datetime "created_at", null: false
    t.integer "location_id"
    t.string "name", null: false
    t.json "properties", default: {}
    t.string "subrole"
    t.datetime "updated_at", null: false
    t.index ["character_id"], name: "index_items_on_character_id"
    t.index ["location_id"], name: "index_items_on_location_id"
    t.index ["subrole"], name: "index_items_on_subrole"
  end

  create_table "journeys", force: :cascade do |t|
    t.integer "cooldown_until_game_time", default: 0, null: false
    t.datetime "created_at", null: false
    t.float "cursor_x", null: false
    t.float "cursor_y", null: false
    t.integer "destination_id", null: false
    t.integer "elapsed_minutes", default: 0, null: false
    t.float "origin_x", null: false
    t.float "origin_y", null: false
    t.integer "started_at_game_time", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["destination_id"], name: "index_journeys_on_destination_id"
  end

  create_table "locations", force: :cascade do |t|
    t.string "biome"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "faction_id"
    t.string "name", null: false
    t.integer "parent_id"
    t.json "properties", default: {}
    t.datetime "updated_at", null: false
    t.float "x"
    t.float "y"
    t.index ["biome"], name: "index_locations_on_biome"
    t.index ["faction_id"], name: "index_locations_on_faction_id"
    t.index ["parent_id"], name: "index_locations_on_parent_id"
  end

  create_table "pending_appearances", force: :cascade do |t|
    t.integer "actor_character_id"
    t.integer "anchor_location_id"
    t.datetime "created_at", null: false
    t.integer "earliest_at", null: false
    t.text "intent_text", null: false
    t.integer "origin_character_id"
    t.integer "origin_faction_id"
    t.integer "resolved_at"
    t.string "scope", null: false
    t.integer "target_character_id", null: false
    t.integer "triggered_by_event_id"
    t.datetime "updated_at", null: false
    t.index ["actor_character_id"], name: "index_pending_appearances_on_actor_character_id"
    t.index ["anchor_location_id", "resolved_at"], name: "idx_pending_appearances_anchor_unresolved"
    t.index ["anchor_location_id"], name: "index_pending_appearances_on_anchor_location_id"
    t.index ["origin_character_id"], name: "index_pending_appearances_on_origin_character_id"
    t.index ["origin_faction_id"], name: "index_pending_appearances_on_origin_faction_id"
    t.index ["target_character_id", "resolved_at"], name: "idx_pending_appearances_target_unresolved"
    t.index ["target_character_id"], name: "index_pending_appearances_on_target_character_id"
    t.index ["triggered_by_event_id"], name: "index_pending_appearances_on_triggered_by_event_id"
  end

  create_table "quest_steps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.integer "fulfilled_at_game_time"
    t.string "fulfillment_kind", null: false
    t.integer "opened_at_game_time"
    t.integer "position", null: false
    t.integer "quest_id", null: false
    t.json "related_event_ids", default: []
    t.string "state", default: "pending", null: false
    t.integer "target_character_id"
    t.integer "target_item_id"
    t.integer "target_location_id"
    t.datetime "updated_at", null: false
    t.index ["quest_id", "position"], name: "index_quest_steps_on_quest_id_and_position", unique: true
    t.index ["quest_id"], name: "index_quest_steps_on_quest_id"
    t.index ["state"], name: "index_quest_steps_on_state"
    t.index ["target_character_id"], name: "index_quest_steps_on_target_character_id"
    t.index ["target_item_id"], name: "index_quest_steps_on_target_item_id"
    t.index ["target_location_id"], name: "index_quest_steps_on_target_location_id"
  end

  create_table "quests", force: :cascade do |t|
    t.string "archetype_id", null: false
    t.integer "city_location_id", null: false
    t.datetime "created_at", null: false
    t.integer "created_event_id"
    t.integer "giver_character_id", null: false
    t.string "name", null: false
    t.integer "resolved_event_id"
    t.string "state", default: "offered", null: false
    t.text "summary", null: false
    t.datetime "updated_at", null: false
    t.index ["archetype_id"], name: "index_quests_on_archetype_id"
    t.index ["city_location_id"], name: "index_quests_on_city_location_id"
    t.index ["giver_character_id"], name: "index_quests_on_giver_character_id"
    t.index ["state"], name: "index_quests_on_state"
  end

  create_table "turn_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.text "input"
    t.integer "location_id"
    t.text "narration"
    t.text "narration_prompt"
    t.text "reasoning_prompt"
    t.text "reasoning_tool_calls"
    t.integer "turn_number", null: false
    t.datetime "updated_at", null: false
    t.index ["location_id"], name: "index_turn_logs_on_location_id"
    t.index ["turn_number"], name: "index_turn_logs_on_turn_number"
  end

  add_foreign_key "characters", "locations"
  add_foreign_key "event_participants", "characters"
  add_foreign_key "event_participants", "events"
  add_foreign_key "events", "locations"
  add_foreign_key "items", "characters"
  add_foreign_key "items", "locations"
  add_foreign_key "journeys", "locations", column: "destination_id"
  add_foreign_key "locations", "factions"
  add_foreign_key "locations", "locations", column: "parent_id"
  add_foreign_key "pending_appearances", "characters", column: "actor_character_id"
  add_foreign_key "pending_appearances", "characters", column: "origin_character_id"
  add_foreign_key "pending_appearances", "characters", column: "target_character_id"
  add_foreign_key "pending_appearances", "events", column: "triggered_by_event_id"
  add_foreign_key "pending_appearances", "factions", column: "origin_faction_id"
  add_foreign_key "pending_appearances", "locations", column: "anchor_location_id"
  add_foreign_key "quest_steps", "characters", column: "target_character_id"
  add_foreign_key "quest_steps", "items", column: "target_item_id"
  add_foreign_key "quest_steps", "locations", column: "target_location_id"
  add_foreign_key "quest_steps", "quests"
  add_foreign_key "quests", "characters", column: "giver_character_id"
  add_foreign_key "quests", "events", column: "created_event_id"
  add_foreign_key "quests", "events", column: "resolved_event_id"
  add_foreign_key "quests", "locations", column: "city_location_id"
end
