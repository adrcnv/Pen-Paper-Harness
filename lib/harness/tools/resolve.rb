module Harness
  module Tools
    # Mechanical resolution — every stat check flows through here. Combat,
    # skill checks, perception, persuade, stealth, balance, endurance — all
    # one pipe. The LLM picks the stat axis (or names an ability) and
    # describes the action in prose; the core rolls, applies modifiers,
    # determines outcome, and commits an event. The LLM never sees dice
    # numbers or stat values.
    #
    # Two modes:
    #   Stat-only  — actor_id + stat + action. Raw check against any stat.
    #   Ability    — actor_id + ability_name + action. Looks up the ability
    #                on the actor's abilities list; uses ability.stat and
    #                ability.opposed_by / difficulty. Errors structurally if
    #                the actor doesn't have the ability (rigor — no
    #                hallucinated capabilities).
    class Resolve < Base
      STATS              = ::Character::STATS
      VALID_DIFFICULTIES = ::Harness::Dice::VALID_DIFFICULTIES

      def self.tool_name
        "resolve"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Resolve a mechanical action. EITHER pass `stat` for a raw stat check OR pass `ability_name` to invoke a specific ability the actor has (looked up on their abilities list; errors if absent). With ability mode, the ability's own stat and opposed_by override any you pass. Optionally targets another character (opposed check), or specifies a difficulty tier (unopposed DC). Optionally uses an item from the actor's inventory whose properties.roll_modifier adds to the roll. You never see dice, stat values, or DC — only the outcome tier and margin. Every call logs a personal-scope event.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "actor_id"     => { "type" => "integer", "description" => "id of the Character attempting the action" },
              "stat"         => { "type" => "string", "enum" => STATS, "description" => "which stat the actor rolls (required if ability_name absent; ignored if ability_name given)" },
              "ability_name" => { "type" => "string", "description" => "name of a specific ability on the actor's abilities list; case-insensitive match" },
              "action"       => { "type" => "string", "description" => "short prose describing what is being attempted (2-10 words)" },
              "target_id"    => { "type" => "integer", "description" => "optional target Character; presence triggers an opposed check" },
              "target_stat"  => { "type" => "string", "enum" => STATS, "description" => "optional stat the target defends with; defaults to ability.opposed_by (ability mode) or matches actor's stat (stat-only mode)" },
              "item_id"      => { "type" => "integer", "description" => "optional Item in the actor's inventory; its properties.roll_modifier adds to the roll" },
              "difficulty"   => { "type" => "string", "enum" => VALID_DIFFICULTIES, "description" => "optional unopposed DC tier; defaults to 'moderate' or ability.difficulty" },
              "roll_modifier" => { "type" => "integer", "description" => "optional ±N tactical bonus from circumstance, clamped to [-5, +5]. POSITIVE: surprise attack +3, flanking/cornered +2, exploiting an exposed weakness +2, prepared trap +3, exceptional positioning +2, surprise+ambush+terrain +5. NEGATIVE: blinded/dark -2, exhausted/wounded -1 to -2, fighting prone -2, awkward angle -1, mid-task interruption -2. Use for tactical creativity by the player; do NOT use to compensate for stat differences (that's the dice's job). Only on actions where circumstance plausibly matters." },
              "time_minutes" => { "type" => "integer", "description" => "in-fiction minutes this action takes. Combat round ~1, lock-pick ~1-3, perception sweep ~1-2, conversation exchange ~3-10, extended persuasion ~30+. You judge from the action prose." }
            },
            "required" => [ "actor_id", "action", "time_minutes" ]
          }
        }
      end

      def call(args, context)
        actor_id     = args["actor_id"]
        action       = args["action"]
        ability_name = args["ability_name"]
        stat_arg     = args["stat"]

        return { "error" => "actor_id required" } if actor_id.nil?
        return { "error" => "action must be a non-empty string" } unless action.is_a?(String) && !action.strip.empty?

        actor = ::Character.find_by(id: actor_id)
        return { "error" => "no character with id=#{actor_id}" } unless actor

        # Resolve the ability if named. Lookup is against the actor's own
        # abilities array (set at character creation by the Hatchery). No
        # lazy materialization — the seam moved upstream.
        #
        # Special case: ability_name == "unarmed_strike" is a hardcoded
        # fallback everyone can use — no library lookup, no use spending,
        # no tag requirements. Punch.
        ability = nil
        ability_index = nil  # position in actor.abilities, for uses_remaining writeback
        if ability_name.is_a?(String) && ability_name.downcase.strip == "unarmed_strike"
          ability = unarmed_strike_ability
          # ability_index stays nil — signals "no use-count writeback"
        elsif ability_name.is_a?(String) && !ability_name.strip.empty?
          ability, ability_index = find_ability_with_index(actor, ability_name)
          return ability_not_found_error(actor, ability_name) if ability.nil?

          # Use-count gate: if exhausted since last rest, refuse the call
          # cleanly (the reasoning loop should narrate fallback to a basic
          # attack instead).
          if (ability["uses_remaining"] || 0) <= 0
            return {
              "error" => "ability=#{ability_name.inspect} has no uses remaining until rest. Fall back to a basic attack or different ability."
            }
          end
        end

        # Stat: ability mode uses ability.stat (explicit override) or the
        # caster's class primary_stat (the common path). Stat-only mode
        # requires the stat arg. See Abilities::Library.stat_for_ability.
        stat = if ability
          ::Harness::Abilities::Library.stat_for_ability(ability: ability, character_class: actor.character_class)
        else
          stat_arg
        end
        return { "error" => "stat must be one of: #{STATS.join(', ')} (or pass ability_name)" } unless STATS.include?(stat)

        # Tag-gating: an ability with requires_tags must be backed by an
        # owned item supplying those tags. Heavy_strike requires :weapon;
        # Fireball requires :magical_implement; etc. Failed gate returns an
        # error so the LLM can fall back to unarmed_strike (a hardcoded
        # fallback further down).
        required_tags = ability && Array(ability["requires_tags"])
        if ability && required_tags.any? && !::Harness::Items::Modifiers.has_required_tags?(actor, required_tags)
          return {
            "error" => "ability=#{ability_name.inspect} requires item tags=#{required_tags.inspect} but actor has none. Try ability_name='unarmed_strike' for a basic attack."
          }
        end


        target      = nil
        target_stat = resolve_target_stat(ability, args["target_stat"], stat)
        if args["target_id"]
          target = ::Character.find_by(id: args["target_id"])
          return { "error" => "no character with id=#{args["target_id"]}" } unless target
          # Dead targets are inert. They're surfaced in query_scene's
          # present_corpses so narration can mention the body, but they
          # don't take actions and they can't be attacked again. Looting
          # coins from a corpse goes through transfer_coins (which works
          # against any character row regardless of HP); dropped items
          # appear in present_items at this location after the kill.
          # Dead = initialized (max_hp > 0) AND zeroed; uninitialized rows
          # (max_hp == 0) count as alive (matches Assembler's partition).
          if target.max_hp.to_i > 0 && target.current_hp.to_i <= 0
            return { "error" => "target id=#{target.id} (#{target.name}) is already dead. They are surfaced in present_corpses, not present_characters. Loot coins via transfer_coins; dropped items are in present_items." }
          end
          if target_stat && !STATS.include?(target_stat)
            return { "error" => "target_stat must be one of: #{STATS.join(', ')}" }
          end
        end

        # Watcher-attacked transition (combat-mode). If the target is a
        # `watch`-state real character, promote them to combatant on the
        # opposite side from the attacker (KISS attackee-opposes rule) and
        # splice a fresh initiative slot in next round. They start taking
        # turns immediately the next time the round driver picks them up.
        if context.active_scene&.in_combat? && target
          state = context.active_scene.combat
          if state.watcher?(target.id) && state.combatant?(actor.id)
            attacker_side = state.side_of(actor.id)
            opposing_side = state.sides.values.uniq.find { |s| s != attacker_side } || "watchers"
            state.promote_watcher!(target.id, side: opposing_side)
            state.insert_initiative_after_current!(target.id)
          end
        end

        # Combat-mode range gate. Only applies when the scene is in combat,
        # an ability is supplied (stat-only checks bypass), and the action
        # has a target. The LLM gets a structural error and picks something
        # else — saves the round driver from trying to dispatch impossible
        # actions (swing a melee weapon at a far foe, etc).
        if context.active_scene&.in_combat? && ability && target
          range_error = check_combat_range(context.active_scene.combat, actor, target, ability)
          return range_error if range_error
        end

        item = nil
        if args["item_id"]
          item = ::Item.find_by(id: args["item_id"])
          return { "error" => "no item with id=#{args["item_id"]}" } unless item
          unless item.character_id == actor.id
            return { "error" => "item id=#{item.id} is not in actor's inventory" }
          end
        end

        difficulty = args["difficulty"] || ability&.dig("difficulty") || "moderate"
        return { "error" => "difficulty must be one of: #{VALID_DIFFICULTIES.join(', ')}" } unless VALID_DIFFICULTIES.include?(difficulty)

        materialize_stats(actor, context)
        materialize_stats(target, context) if target

        # Two roll-modifier sources: the equipped item's property (mechanical,
        # set at item creation) and the LLM's tactical arg (situational, from
        # player creativity). Sum them, then clamp the SITUATIONAL component
        # to [-5, +5] before adding — guards against the LLM passing wild
        # numbers to override the dice. Item modifier is NOT clamped (the
        # library authors set it; trust the YAML).
        item_modifier = (item&.properties || {})["roll_modifier"].to_i
        situational   = args["roll_modifier"].is_a?(Integer) ? args["roll_modifier"].clamp(-5, 5) : 0
        roll_modifier = item_modifier + situational

        # Item-modifier rollup: every owned item with a stat-add modifier
        # for this check's stat contributes. e.g., a +1 STR sword bumps
        # the actor's effective STR for an attack roll.
        actor_stat_value = actor.stat(stat) + ::Harness::Items::Modifiers.stat_bonus(actor, stat)

        # Phase: on_attack_roll. Items can set crit_threshold_mod or
        # force_critical here. The outcome hash is the carrier — handlers
        # write into it; we read from it after the dice land.
        attack_outcome = {}
        ::Harness::Items::TriggerRegistry.fire_phase(
          phase:   :on_attack_roll,
          actor:   actor,
          target:  target,
          ability: ability,
          outcome: attack_outcome
        )

        # Dice modes:
        # - ability with opposed_by = null: always unopposed (difficulty), even if target set
        # - ability with opposed_by set: opposed check if target present, else unopposed
        # - stat-only: opposed if target present, else unopposed
        effective_target_stat = target && target_stat ? target.stat(target_stat) : nil

        outcome = ::Harness::Dice.check(
          actor_stat:    actor_stat_value,
          target_stat:   effective_target_stat,
          difficulty:    difficulty,
          roll_modifier: roll_modifier
        )

        # auto_succeed_check: if an item provided a one-shot guaranteed crit
        # this attack, override the dice outcome.
        if attack_outcome[:force_critical]
          outcome = ::Harness::Dice::Outcome.new(result: "critical_success", margin: "decisive", critical: true)
        end

        time_minutes = args["time_minutes"].is_a?(Integer) ? args["time_minutes"] : 1
        ::Harness::Clock.advance(context, minutes: time_minutes, reason: "resolve(#{action.slice(0, 30)})")

        # Damage application: only on hit (success or critical_success), only
        # for damage abilities, only when there's a target. Doubled on
        # critical. Item modifiers add bonus damage (e.g., +1d4 on attack);
        # on_damage_taken phase fires on the target (damage_resist /
        # reflect_damage / bonus_damage_vs_tag); on_lethal fires if the
        # damage would zero them (death_save can clamp HP back to 1).
        damage = 0
        target_killed = false
        dropped_items = []
        target_was_alive_before = target ? target.current_hp.to_i > 0 : false
        if ability && ability["effect_kind"] == "damage" && target && %w[success critical_success].include?(outcome.result)
          damage = ::Harness::Abilities::DiceFormula.roll_ability(
            ability:      ability,
            caster_level: actor.level
          )
          damage += ::Harness::Items::Modifiers.bonus_damage(actor, on: "attack")
          damage *= 2 if outcome.critical

          # on_damage_dealt fires on the ATTACKER's items (bonus_damage_vs_tag
          # adds dice when the target matches a tag like "undead"). Mutates
          # the damage value via outcome[:damage_modifier].
          dealt_outcome = { damage_modifier: 0 }
          ::Harness::Items::TriggerRegistry.fire_phase(
            phase:    :on_damage_dealt,
            actor:    actor,
            target:   target,
            ability:  ability,
            damage:   damage,
            outcome:  dealt_outcome
          )
          damage += dealt_outcome[:damage_modifier].to_i

          # on_damage_taken fires on the TARGET's items (damage_resist,
          # reflect_damage). damage_modifier is an integer offset (negative
          # for reduction). reflect_damage stashes a value to apply back.
          taken_outcome = { damage_modifier: 0, reflect_damage: 0 }
          ::Harness::Items::TriggerRegistry.fire_phase(
            phase:    :on_damage_taken,
            actor:    target,    # ← target's perspective; "actor" of the trigger context is the one bearing the items
            target:   actor,
            ability:  ability,
            damage:   damage,
            outcome:  taken_outcome
          )
          damage = [ damage + taken_outcome[:damage_modifier].to_i, 0 ].max

          # on_lethal: about-to-zero check. death_save can clamp HP to a
          # survivable value; the trigger fires BEFORE apply_damage! so the
          # save mutates ctx.outcome[:revive_to_hp] and we honor it.
          lethal_outcome = {}
          would_zero = damage >= target.current_hp.to_i && target.current_hp.to_i.positive?
          if would_zero
            ::Harness::Items::TriggerRegistry.fire_phase(
              phase:    :on_lethal,
              actor:    target,
              target:   actor,
              ability:  ability,
              damage:   damage,
              outcome:  lethal_outcome
            )
          end

          if lethal_outcome[:revive_to_hp]
            # Death-save fired. Apply the clamp; do NOT zero HP.
            target.update!(current_hp: lethal_outcome[:revive_to_hp])
          else
            apply_damage!(target, damage)
          end

          # Reflect damage: apply to actor after target took the hit (or was
          # saved). Doesn't itself fire on_damage_taken on the actor — would
          # be infinite recursion if both wore reflect amulets. Phase 1.
          if (reflected = taken_outcome[:reflect_damage].to_i) > 0
            apply_damage!(actor, reflected)
          end

          # heal_on_kill needs to know if the target dropped. on_damage_dealt
          # fires twice: once before for damage modifiers, again here so
          # heal-on-kill can read target_killed. Cheap; second pass usually no-ops.
          target_killed = lethal_outcome[:revive_to_hp].nil? && target.reload.current_hp <= 0
          if target_killed
            kill_outcome = { target_killed: true }
            ::Harness::Items::TriggerRegistry.fire_phase(
              phase:    :on_damage_dealt,
              actor:    actor,
              target:   target,
              ability:  ability,
              damage:   damage,
              outcome:  kill_outcome
            )
            # Death-loot: detach the deceased's items and anchor them to
            # the location for pickup. Coins stay on the corpse — looted
            # via transfer_coins. Surfaced on the outcome so the reasoning
            # loop knows what dropped without re-querying.
            dropped_items = ::Harness::Items::Loot.drop_to_floor(target)
            clear_follower_flag!(target)
            # In-combat death cleanup: clear the deceased's engagement edge
            # so survivors don't keep showing "engaged_with: <corpse-id>"
            # in the NPC payload (which costs an auto-engage retry every
            # time they try to attack a different live target). We do NOT
            # remove from initiative/sides — deleting from initiative
            # mid-round shifts indices and skips the next combatant's slot.
            # The dead-actor skip in Combat::Loop#run_slots handles their
            # slot; Termination filters dead from alive-side counts.
            if context.active_scene&.in_combat?
              cstate = context.active_scene.combat
              cstate.disengage!(target.id) if cstate.combatant?(target.id)
            end
          end
        end

        # Kill detection + XP award: only when the player drops a previously-
        # alive NPC to 0 with this resolve. NPC-on-NPC and NPC-on-player kills
        # don't track XP (only the player levels). XP::award! handles auto-
        # leveling-up while the new total clears next thresholds. The result
        # is surfaced on the outcome so the reasoning loop / narration can
        # mention it.
        xp_award = nil
        if actor.is_a?(::Player) && target.is_a?(::Npc) && target_was_alive_before && target.reload.current_hp <= 0
          xp_amount = ::Harness::Character::XP.for_kill(
            killer_level: actor.level,
            victim_level: target.level
          )
          xp_award = ::Harness::Character::XP.award!(actor, xp_amount)
        end

        # Use-count writeback: any successful CALL of an ability spends a use
        # (failure still costs the action, matching D&D-shape spell-slot
        # economy where a missed Fireball still expended the slot). Errors
        # (target missing, exhausted) returned earlier and never reach here.
        spend_use!(actor, ability_index) if ability && ability_index

        event = log_event(actor, target, stat, target_stat, ability, action, outcome, item, damage, context)

        result = {
          "outcome"      => outcome.result,
          "margin"       => outcome.margin,
          "critical"     => outcome.critical,
          "roll"         => outcome.roll,
          "against"      => outcome.against,
          "action"       => action,
          "stat"         => stat,
          "target_stat"  => target ? target_stat : nil,
          "roll_modifier" => roll_modifier != 0 ? roll_modifier : nil,
          "ability_name" => ability&.dig("name"),
          "damage"       => damage > 0 ? damage : nil,
          "target_hp"    => target ? "#{target.reload.current_hp}/#{target.max_hp}" : nil,
          "target_downed" => target && target.reload.properties.is_a?(Hash) && target.properties["stance"] == "downed",
          "uses_remaining" => (ability && ability_index) ? actor.reload.abilities[ability_index]["uses_remaining"] : nil,
          "xp_gained"    => xp_award&.dig(:gained),
          "leveled_up"   => xp_award && xp_award[:levels_gained] > 0,
          "new_level"    => xp_award && xp_award[:levels_gained] > 0 ? xp_award[:new_level] : nil,
          "abilities_gained" => xp_award && xp_award[:abilities_gained].any? ? xp_award[:abilities_gained].map { |a| a["name"] } : nil,
          "actor_id"     => actor.id,
          "target_id"    => target&.id,
          "item_id"      => item&.id,
          "event_id"     => event.id,
          "dropped_items" => dropped_items.any? ? dropped_items.map { |it| { "id" => it.id, "name" => it.name } } : nil,
          "looted_coins" => (target_killed && target&.coins.to_i.positive?) ? target.coins : nil
        }.compact

        # Combat slot bookkeeping. Mark the action token spent IFF the actor
        # is the current initiative slot (resolve gets called outside slots
        # too — escape's free-hit, watcher promotion paths — and those must
        # not advance the wrong slot). Always record the action into the
        # round buffer so end-of-round narration can render it.
        if context.active_scene&.in_combat?
          state = context.active_scene.combat
          if state&.combatant?(actor.id)
            if state.current_actor_id == actor.id
              state.mark_acted!(actor.id)
            end
            state.record_action!(
              "tool"       => "resolve",
              "actor_id"   => actor.id,
              "actor_name" => actor.name,
              "args"       => args,
              "result"     => result
            )
          end
        end

        result
      end

      private

      # Combat-mode range gate. Returns nil if the action is in range,
      # or {error: ...} if it isn't. Rules:
      # - close: actor + target both engaged AND engaged with each other
      # - near:  target cannot be at far
      # - far:   always allowed
      # - self / unknown: always allowed (no range gate)
      def check_combat_range(state, actor, target, ability)
        case ability["range"]
        when "close"
          actor_pos  = state.position_of(actor.id)
          target_pos = state.position_of(target.id)
          if actor_pos != "engaged" || target_pos != "engaged" || state.engaged_with_of(actor.id) != target.id
            return { "error" => "ability=#{ability['name'].inspect} is melee range (close) — both you and #{target.name} must be engaged with each other. Use move_to to engage first, or pick a near/far ability." }
          end
        when "near"
          if state.position_of(target.id) == "far"
            return { "error" => "ability=#{ability['name'].inspect} cannot reach far targets. #{target.name} is at far range — close the distance with move_to or pick a far-range ability." }
          end
        end
        nil
      end

      # Hardcoded fallback ability — no library entry, no use spending,
      # no tag requirements. Always available; the LLM reaches for it
      # when the ability they wanted gates on item tags they don't have.
      UNARMED_STRIKE = {
        "name"           => "Unarmed Strike",
        "id"             => "unarmed_strike",
        "effect_kind"    => "damage",
        "damage_dice"    => "1d4",
        "damage_per_level" => nil,
        "stat"           => "strength",
        "opposed_by"     => "dexterity",
        "min_level"      => 1,
        "uses_per_rest"  => 0,
        "uses_remaining" => 0,
        "tags"           => [ "martial", "unarmed" ],
        "requires_tags"  => [],
        "range"          => "close"
      }.freeze

      def unarmed_strike_ability
        UNARMED_STRIKE.dup
      end

      def find_ability(actor, name)
        Array(actor.abilities).find { |a| a["name"].to_s.downcase == name.downcase }
      end

      # Returns [ability_hash, index_in_actor_abilities_array]. Index is
      # used by spend_use! to write the decremented uses_remaining back to
      # the JSON column without a full re-roll.
      def find_ability_with_index(actor, name)
        Array(actor.abilities).each_with_index do |a, i|
          return [ a, i ] if a["name"].to_s.downcase == name.downcase
        end
        [ nil, nil ]
      end

      def apply_damage!(target, damage)
        new_hp = [ target.current_hp - damage, 0 ].max
        attrs  = { current_hp: new_hp }
        if new_hp <= 0
          props = (target.properties || {}).merge("stance" => "downed")
          attrs[:properties] = props
        end
        target.update!(attrs)
      end

      # A dead follower is no longer following — strip the flag so query_scene
      # and transition's follower-sweep don't keep dragging the corpse around.
      # The body stays at the location it died at (location_id unchanged).
      def clear_follower_flag!(target)
        return unless target.is_a?(::Npc)
        props = target.properties || {}
        return unless props["following_player"] == true
        target.update!(properties: props.except("following_player"))
      end

      def spend_use!(actor, ability_index)
        abilities = actor.abilities.dup
        row = abilities[ability_index].dup
        row["uses_remaining"] = [ row["uses_remaining"].to_i - 1, 0 ].max
        abilities[ability_index] = row
        actor.update!(abilities: abilities)
      end

      def ability_not_found_error(actor, name)
        available = Array(actor.abilities).map { |a| a["name"] }
        if available.empty?
          { "error" => "actor has no abilities; ability_name=#{name.inspect} cannot be used. Fall back to a stat check." }
        else
          { "error" => "ability=#{name.inspect} not on actor. Available: #{available.join(', ')}" }
        end
      end

      # In ability mode: opposed_by is authoritative (including null = unopposed).
      # In stat-only mode: target_stat arg, falling back to echoing the actor's stat.
      def resolve_target_stat(ability, target_stat_arg, stat)
        if ability
          ability["opposed_by"]  # may be nil → unopposed
        else
          target_stat_arg || stat
        end
      end

      def materialize_stats(character, context)
        return if context.llm_grunt.nil?
        ::Harness::Stats::Materializer.new(llm_client: context.llm_grunt)
                                      .materialize_if_needed(character)
      end

      def log_event(actor, target, stat, target_stat, ability, action, outcome, item, damage, context)
        participants = [ { character: actor, role: "actor" } ]
        participants << { character: target, role: "target" } if target

        details = {
          "resolve" => {
            "action"       => action,
            "ability_name" => ability&.dig("name"),
            "stat"         => stat,
            "target_stat"  => target ? target_stat : nil,
            "item_id"      => item&.id,
            "outcome"      => outcome.result,
            "margin"       => outcome.margin,
            "critical"     => outcome.critical,
            "damage"       => damage > 0 ? damage : nil
          }.compact
        }

        ::Harness::Event::ForwardAppender.append(
          game_time:    context.game_time,
          scope:        "personal",
          location:     actor.location,
          details:      details,
          participants: participants
        )
      end
    end
  end
end
