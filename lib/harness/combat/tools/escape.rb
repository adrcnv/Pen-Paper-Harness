module Harness
  module Combat
    module Tools
      # Combat-only. Attempt to disengage and exit the scene.
      #
      # Mechanics:
      #   1. DEX check. Opposed vs the engaged hostile's DEX if engaged;
      #      otherwise unopposed moderate difficulty.
      #   2. Success: actor's location_id moves to the scene's parent
      #      (NPC fleeing a top-level wilderness leaf goes nil — "dispersed
      #      into the wild"; player without a parent stays put but combat
      #      clears for them, scene_dirty fires). Combat state cleared
      #      for the actor (removed from sides + initiative).
      #   3. Failure: engaged hostile (if any) gets a FREE attack against
      #      the actor — invoked through the normal Resolve pipe so items,
      #      triggers, and events all fire. Slot closes (action + move
      #      both spent on the failed escape). Actor stays in combat.
      #
      # Per-actor decision; no chain-flee. Each remaining combatant decides
      # for themselves on their own slot.
      class Escape < ::Harness::Tools::Base
        def self.tool_name
          "escape"
        end

        def self.schema
          {
            "name"        => tool_name,
            "description" => "Combat-only. Attempt to disengage and exit the scene. DEX check vs the engaged hostile's DEX (or moderate DC if not engaged). Success: you exit. Failure: the engaged hostile lands a free hit and you stay in combat — your slot also closes (action AND move spent). One try per slot. Use when you'd rather run than fight on.",
            "input_schema" => {
              "type"       => "object",
              "properties" => {
                "actor_id" => { "type" => "integer", "description" => "the escaping combatant's id; must be the current initiative slot" }
              },
              "required" => [ "actor_id" ]
            }
          }
        end

        def call(args, context)
          scene = context.active_scene
          return { "error" => "no active scene" } unless scene
          return { "error" => "not in combat" } unless scene.in_combat?

          state    = scene.combat
          actor_id = args["actor_id"].to_i
          actor    = ::Character.find_by(id: actor_id)
          return { "error" => "actor_id #{actor_id} is not a combatant" } unless state.combatant?(actor_id)
          return { "error" => "no character with id=#{actor_id}" } unless actor
          return { "error" => "it is not actor_id=#{actor_id}'s turn (current actor is #{state.current_actor_id})" } unless state.current_actor_id == actor_id

          opponent_id = state.engaged_with_of(actor_id)
          opponent    = opponent_id ? ::Character.find_by(id: opponent_id) : nil

          outcome = roll_escape(actor, opponent)

          result =
            if outcome.result == "success" || outcome.result == "critical_success"
              apply_success!(actor, scene, state, context)
              {
                "ok"          => true,
                "escaped"     => true,
                "actor_id"    => actor_id,
                "outcome"     => outcome.result,
                "margin"      => outcome.margin,
                "destination" => actor.reload.location_id
              }
            else
              free_hit_result = apply_failure!(actor, opponent, state, context)
              {
                "ok"            => true,
                "escaped"       => false,
                "actor_id"      => actor_id,
                "outcome"       => outcome.result,
                "margin"        => outcome.margin,
                "free_hit"      => free_hit_result,
                "slot_complete" => true
              }
            end

          # State may have been cleared by apply_success!; re-grab if present.
          combat_state = scene.combat
          combat_state&.record_action!(
            "tool"       => "escape",
            "actor_id"   => actor_id,
            "actor_name" => actor.name,
            "args"       => args,
            "result"     => result
          )

          result
        end

        private

        def roll_escape(actor, opponent)
          actor_dex = actor.stat(:dexterity)
          if opponent
            ::Harness::Dice.check(
              actor_stat:    actor_dex,
              target_stat:   opponent.stat(:dexterity),
              difficulty:    "moderate",
              roll_modifier: 0
            )
          else
            ::Harness::Dice.check(
              actor_stat:  actor_dex,
              difficulty:  "moderate"
            )
          end
        end

        def apply_success!(actor, scene, state, context)
          state.remove_combatant!(actor.id)
          state.disengage!(actor.id)

          parent_id = scene.location&.parent_id
          if actor.is_a?(::Player) && parent_id.nil?
            # Top-level wilderness — player can't go nil. Stay put, signal
            # rebuild so the scene reassembles fresh (without this combat
            # if the termination check ends it). Multi-hop wilderness flee
            # destinations are the multi-hop-travel work, not this.
            context.scene_dirty = true
          else
            actor.update!(location_id: parent_id)
            scene.snapshot.present_characters.delete(actor) if scene.snapshot
            context.scene_dirty = true if actor.is_a?(::Player)
          end
        end

        def apply_failure!(actor, opponent, state, context)
          state.mark_acted!(actor.id)
          state.mark_moved!(actor.id)

          return { "no_opponent" => true } unless opponent

          # Free hit through the regular resolve pipe so items, triggers,
          # event log, and damage rolls all fire normally. Pick the
          # opponent's first close-range damage ability or fall back to
          # unarmed_strike.
          ability_name = pick_free_hit_ability(opponent)
          ::Harness::Tools::Resolve.new.call(
            {
              "actor_id"     => opponent.id,
              "ability_name" => ability_name,
              "action"       => "free attack on fleeing #{actor.name}",
              "target_id"    => actor.id,
              "time_minutes" => 0
            },
            context
          )
        end

        def pick_free_hit_ability(opponent)
          melee = Array(opponent.abilities).find do |a|
            a["effect_kind"] == "damage" && a["range"] == "close" && (a["uses_remaining"] || 0) > 0
          end
          melee ? melee["name"] : "unarmed_strike"
        end
      end
    end
  end
end
