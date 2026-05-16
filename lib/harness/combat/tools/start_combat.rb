module Harness
  module Combat
    module Tools
      # Explicit transition into combat sub-mode. Called by the reasoning
      # loop the moment hostility crystallizes — the player declares an
      # attack, an NPC swings first, an ambush triggers. From here, Ruby
      # drives the round loop and the resolver serves the narrow combat
      # toolset (move_to / escape / end_turn / resolve / mutate_character).
      #
      # Validates the proposed sides, evicts unnamed extras silently,
      # runs one bystander deliberation per uncommitted real character
      # (small-model, biased to flee/watch), rolls initiative once, and
      # commits a personal-scope event marking combat start.
      class StartCombat < ::Harness::Tools::Base
        def self.tool_name
          "start_combat"
        end

        def self.schema
          {
            "name"        => tool_name,
            "description" => "Enter combat mode. Provide the explicit sides (attacker + defender, plus any others). Every member id MUST come from `query_scene`'s `present_characters[].id` (or the player's id from INPUT.player.id) — do NOT use ids from prior scenes, recent_history, or invent them. If you're unsure who is present, call query_scene FIRST and use only those ids. Members listed must be just the named NPCs you actually want as combatants; unnamed extras evict automatically, you do not enumerate them. The player must appear on exactly one side. Followers (properties.following_player=true) auto-include on the player's side. Other present characters get one deliberation call each (flee/watch/join). Initiative is rolled once (1d20 + DEX_mod, descending). After this call, the tool surface switches to combat-mode (move_to, escape, end_turn, resolve, mutate_character, propose_event, query_scene).",
            "input_schema" => {
              "type"       => "object",
              "properties" => {
                "sides" => {
                  "type"  => "array",
                  "items" => {
                    "type"       => "object",
                    "properties" => {
                      "name"    => { "type" => "string", "description" => "free-text side label, e.g. 'player_party' / 'marauders' / 'guard_patrol'" },
                      "members" => {
                        "type"  => "array",
                        "items" => { "type" => "integer" },
                        "description" => "character_ids on this side; must all be present_characters in the current scene"
                      }
                    },
                    "required" => [ "name", "members" ]
                  },
                  "description" => "At least two sides; each side has at least one member; no character on more than one side."
                },
                "initiator_id" => { "type" => "integer", "description" => "character_id of whoever swung first (used to inform bystander deliberation); defaults to the player's id." },
                "inciting_beat" => { "type" => "string", "description" => "one-sentence prose describing what kicked the fight off ('the player drew steel on Vek after the accusation'). Surfaces in bystander deliberation prompt and the combat-start event details." }
              },
              "required" => [ "sides", "inciting_beat" ]
            }
          }
        end

        def call(args, context)
          scene = context.active_scene
          return { "error" => "no active scene" } unless scene
          return { "error" => "already in combat" } if scene.in_combat?

          sides = args["sides"]
          inciting_beat = args["inciting_beat"].to_s.strip
          return { "error" => "inciting_beat must be a non-empty string" } if inciting_beat.empty?

          # Scene::Assembler doesn't include Player in present_characters
          # (only Npcs are surfaced). The player is always implicitly present
          # at their location — include them in the validation set so sides
          # can reference them.
          player = ::Player.first
          return { "error" => "no player row" } unless player
          present_ids = scene.present_characters.map(&:id).to_set
          present_ids << player.id

          # ---- shape validation
          validation = validate_sides(sides, present_ids, player.id)
          return validation if validation.is_a?(::Hash) && validation["error"]
          sides = validation # normalized: every side has stringified name + integer members

          # ---- followers auto-include
          followers_added = auto_include_followers(sides, scene, player.id)

          # ---- identify uncommitted: present, real (not extra), not on a side
          committed_ids = sides.flat_map { |s| s["members"] }.to_set
          uncommitted = scene.present_characters.reject { |c| committed_ids.include?(c.id) || c.id == player.id }

          initiator_id = args["initiator_id"]&.to_i || player.id

          # ---- evict extras
          state = ::Harness::Combat::State.new
          (scene.extras || []).each { |ex| state.record_evicted_extra(ex) }
          scene.extras = []

          # ---- per-uncommitted deliberation
          deliberations = []
          uncommitted.each do |char|
            outcome = ::Harness::Combat::BystanderDeliberation.run(
              character:     char,
              sides:         sides,
              initiator:     deliberation_initiator(initiator_id, sides),
              inciting_beat: inciting_beat,
              llm:           context.llm_grunt
            )
            apply_deliberation!(char, outcome, sides, state, scene, player.id)
            deliberations << { "character_id" => char.id, "name" => char.name, "decision" => outcome["decision"], "reason" => outcome["reason"] }
          end

          # ---- populate combat state
          sides.each do |side|
            side["members"].each { |id| state.add_combatant(id, side: side["name"], position: "near") }
          end

          # ---- initiative
          all_combatant_ids = state.all_combatant_ids
          state.initiative = ::Harness::Combat::Initiative.roll(all_combatant_ids)

          # ---- attach to scene
          scene.combat = state

          # ---- commit personal-scope combat-start event
          combat_event = ::Harness::Event::ForwardAppender.append(
            game_time:    context.game_time,
            scope:        "personal",
            location:     scene.location,
            details:      {
              "trigger" => "combat begins",
              "details" => inciting_beat,
              "sides"   => sides.map { |s| { "name" => s["name"], "members" => s["members"] } }
            },
            participants: all_combatant_ids.map { |id| { character: ::Character.find(id), role: "combatant" } }
          )

          {
            "ok"               => true,
            "round"            => state.round,
            "sides"            => sides,
            "initiative"       => state.initiative,
            "current_actor_id" => state.current_actor_id,
            "deliberations"    => deliberations,
            "evicted_extras"   => state.evicted_extras.size,
            "evicted_character_ids" => state.evicted_character_ids,
            "watchers"         => state.watchers,
            "followers_added"  => followers_added,
            "event_id"         => combat_event.id
          }
        end

        private

        def validate_sides(sides, present_ids, player_id)
          # Sorted+frozen for stable error-message ordering.
          present_list = present_ids.to_a.sort
          valid_hint = "valid ids in this scene: #{present_list.inspect} (player=#{player_id})"

          return { "error" => "sides must be an array of at least 2 sides; #{valid_hint}" } unless sides.is_a?(::Array) && sides.size >= 2

          seen_member_ids = ::Set.new
          player_appearances = 0
          normalized = []

          sides.each_with_index do |side, i|
            return { "error" => "sides[#{i}] must be an object with name + members; #{valid_hint}" } unless side.is_a?(::Hash)
            name = side["name"].to_s.strip
            return { "error" => "sides[#{i}].name must be a non-empty string" } if name.empty?

            members = side["members"]
            return { "error" => "sides[#{i}].members must be a non-empty array of character_ids; #{valid_hint}" } unless members.is_a?(::Array) && members.any?

            int_members = members.map(&:to_i)
            int_members.each do |id|
              unless present_ids.include?(id)
                return { "error" => "character_id #{id} on sides[#{i}] is not present in the scene — #{valid_hint}. Re-call start_combat using ONLY ids from that list (drop hallucinated ones)." }
              end
              return { "error" => "character_id #{id} appears on more than one side; #{valid_hint}" } if seen_member_ids.include?(id)
              seen_member_ids << id
              player_appearances += 1 if id == player_id
            end

            normalized << { "name" => name, "members" => int_members }
          end

          if player_appearances != 1
            return { "error" => "player (id=#{player_id}) must appear on exactly one side (got #{player_appearances}); put player_id=#{player_id} on the friendly side. #{valid_hint}" }
          end

          normalized
        end

        def auto_include_followers(sides, scene, player_id)
          player_side = sides.find { |s| s["members"].include?(player_id) }
          followers = scene.present_characters.select do |c|
            c.id != player_id &&
              c.properties.is_a?(::Hash) &&
              c.properties["following_player"] == true
          end

          added = []
          followers.each do |f|
            on_side = sides.find { |s| s["members"].include?(f.id) }
            next if on_side == player_side
            if on_side
              # follower placed on enemy side — error case
              raise "follower #{f.name} (id=#{f.id}) cannot be on a non-player side; un-follow first"
            end
            player_side["members"] << f.id
            added << f.id
          end
          added
        end

        def deliberation_initiator(initiator_id, sides)
          char = ::Character.find_by(id: initiator_id)
          return { "id" => initiator_id, "name" => "unknown", "side" => nil } unless char
          side = sides.find { |s| s["members"].include?(initiator_id) }
          { "id" => char.id, "name" => char.name, "side" => side&.dig("name") }
        end

        def apply_deliberation!(char, outcome, sides, state, scene, player_id)
          case outcome["decision"]
          when "join_player_side"
            player_side = sides.find { |s| s["members"].include?(player_id) }
            player_side["members"] << char.id unless player_side["members"].include?(char.id)
          when "join_enemy_side"
            enemy_side = sides.reject { |s| s["members"].include?(player_id) }.max_by { |s| s["members"].size }
            enemy_side["members"] << char.id unless enemy_side["members"].include?(char.id)
          when "watch"
            state.add_watcher(char.id)
          when "flee"
            flee_destination = scene.location.parent_id
            char.update!(location_id: flee_destination)
            state.record_evicted_character(char.id)
            scene.snapshot.present_characters.delete(char) if scene.snapshot
          end
        end
      end
    end
  end
end
