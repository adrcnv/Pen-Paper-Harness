module Harness
  module Items
    # Named trigger handlers for item effects. Each trigger has:
    #   - phase: when the resolver should fire it (one of PHASES)
    #   - params_schema: required keys + types in the YAML's params field
    #   - apply: pure-Ruby handler called with a Context struct
    #
    # Registered triggers compose into items via the magical YAMLs. The LLM
    # never sees this code path; YAML names triggers from this registry,
    # validated at library-load time.
    #
    # NEVER eval LLM-emitted code. The registry exists precisely so that
    # "interesting magical effects" remain expressible without arbitrary
    # code execution. New triggers grow the registry in Ruby; YAML can
    # only reference existing trigger names.
    module TriggerRegistry
      PHASES = %i[
        on_attack_roll
        on_damage_dealt
        on_damage_taken
        on_lethal
        on_rest
        on_ability_use
      ].freeze

      class UnknownTrigger < StandardError; end
      class InvalidParams  < StandardError; end

      # Trigger handlers receive this context — populated by the resolver
      # at fire time. Not all fields are populated for every phase; e.g.
      # on_rest doesn't have a target. apply methods read what they need.
      Context = Struct.new(
        :actor,    # Character firing / owning the item
        :target,   # Character on the receiving end (may be nil)
        :item,     # Item firing the trigger (so it can self-destruct, etc.)
        :damage,   # Integer damage about to be applied / just applied
        :ability,  # Ability hash if the trigger fires during an ability resolve
        :event_id, # Event id for attribution
        :params,   # Trigger-specific params from the YAML / item row
        :outcome,  # Mutable hash the trigger writes back to (e.g. modified damage)
        keyword_init: true
      )

      # ────────────────────────────────────────────────────────────────────
      # Triggers. Each entry: { phase:, params_schema:, apply: ->(ctx) {...} }
      # ────────────────────────────────────────────────────────────────────

      TRIGGERS = {
        # Clamp HP to params[:hp_after] if damage would reduce it to 0 or below.
        # Optionally destroy the item on use.
        "death_save" => {
          phase:         :on_lethal,
          params_schema: { hp_after: Integer, destroy_on_use: [TrueClass, FalseClass] },
          apply: ->(ctx) {
            saved_hp = ctx.params["hp_after"].to_i
            ctx.outcome[:revive_to_hp] = saved_hp
            ctx.outcome[:triggered]  ||= []
            ctx.outcome[:triggered]  << { trigger: "death_save", item_id: ctx.item&.id, item_name: ctx.item&.name }
            destroy_item!(ctx.item) if ctx.params["destroy_on_use"] && ctx.item
          }
        },

        # Reduce incoming damage by params[:amount]. Optionally restricted to
        # a damage_type (currently a free-text tag the resolver matches on
        # ability tags — a "fire" ability hits an item with damage_resist
        # type=fire). Floors damage at 0.
        "damage_resist" => {
          phase:         :on_damage_taken,
          params_schema: { amount: Integer, type: [String, NilClass] },
          apply: ->(ctx) {
            return unless damage_type_matches?(ctx)
            reduction = ctx.params["amount"].to_i
            ctx.outcome[:damage_modifier] = (ctx.outcome[:damage_modifier] || 0) - reduction
            ctx.outcome[:triggered] ||= []
            ctx.outcome[:triggered] << { trigger: "damage_resist", item_id: ctx.item&.id, amount: reduction }
          }
        },

        # Heal actor by params[:amount] when their attack drops a target.
        "heal_on_kill" => {
          phase:         :on_damage_dealt,
          params_schema: { amount: Integer },
          apply: ->(ctx) {
            return unless ctx.outcome[:target_killed]
            heal = ctx.params["amount"].to_i
            new_hp = [ ctx.actor.current_hp + heal, ctx.actor.max_hp ].min
            ctx.actor.update!(current_hp: new_hp)
            ctx.outcome[:triggered] ||= []
            ctx.outcome[:triggered] << { trigger: "heal_on_kill", item_id: ctx.item&.id, healed: heal }
          }
        },

        # Heal actor by params[:amount] when they rest. Wired into Tools::PassTime.
        "regen_on_rest" => {
          phase:         :on_rest,
          params_schema: { amount: Integer },
          apply: ->(ctx) {
            heal = ctx.params["amount"].to_i
            new_hp = [ ctx.actor.current_hp + heal, ctx.actor.max_hp ].min
            ctx.actor.update!(current_hp: new_hp)
            ctx.outcome[:triggered] ||= []
            ctx.outcome[:triggered] << { trigger: "regen_on_rest", item_id: ctx.item&.id, healed: heal }
          }
        },

        # Add params[:damage_dice] to attack damage when target has params[:tag]
        # (for now, free-text matched against the target's subrole or properties.tags).
        "bonus_damage_vs_tag" => {
          phase:         :on_damage_dealt,
          params_schema: { damage_dice: String, tag: String },
          apply: ->(ctx) {
            return unless target_has_tag?(ctx.target, ctx.params["tag"])
            bonus = ::Harness::Abilities::DiceFormula.roll(ctx.params["damage_dice"])
            ctx.outcome[:damage_modifier] = (ctx.outcome[:damage_modifier] || 0) + bonus
            ctx.outcome[:triggered] ||= []
            ctx.outcome[:triggered] << { trigger: "bonus_damage_vs_tag", item_id: ctx.item&.id, bonus: bonus }
          }
        },

        # +N to crit threshold check. Read by the dice engine via outcome[:crit_threshold_mod].
        # Static modifier — Phase 1 records the intent on outcome; dice integration is later.
        "crit_chance_bonus" => {
          phase:         :on_attack_roll,
          params_schema: { amount: Integer },
          apply: ->(ctx) {
            ctx.outcome[:crit_threshold_mod] = (ctx.outcome[:crit_threshold_mod] || 0) + ctx.params["amount"].to_i
          }
        },

        # Marks outcome with extra_attack flag. Resolver currently records the
        # intent; making it actually grant a second action belongs in Phase D
        # alongside any multi-action turn structure work.
        "extra_attack" => {
          phase:         :on_ability_use,
          params_schema: {},
          apply: ->(ctx) {
            ctx.outcome[:extra_attack_granted] = true
            ctx.outcome[:triggered] ||= []
            ctx.outcome[:triggered] << { trigger: "extra_attack", item_id: ctx.item&.id }
          }
        },

        # Returns params[:fraction] of taken damage to attacker. Fraction is 0..1.
        # Phase 1 records the intent; actual reflection requires the resolver to
        # have an attacker handle on the on_damage_taken phase, which it does
        # only when actor was the target of a resolve call.
        "reflect_damage" => {
          phase:         :on_damage_taken,
          params_schema: { fraction: Float },
          apply: ->(ctx) {
            return unless ctx.params["fraction"].is_a?(Numeric) && ctx.damage&.positive?
            reflected = (ctx.damage * ctx.params["fraction"].to_f).to_i
            ctx.outcome[:reflect_damage] = (ctx.outcome[:reflect_damage] || 0) + reflected
          }
        },

        # Restore one ability use on rest. Resolver picks which ability via
        # params[:ability_id] (matches ability hash's id) or "any" (random).
        "restore_use" => {
          phase:         :on_rest,
          params_schema: { ability_id: [String, NilClass] },
          apply: ->(ctx) {
            abilities = Array(ctx.actor.abilities).map(&:dup)
            target_idx = if ctx.params["ability_id"]
              abilities.index { |a| a["id"] == ctx.params["ability_id"] }
            else
              abilities.each_with_index.select { |a, _| (a["uses_remaining"] || 0) < (a["uses_per_rest"] || 0) }.first&.last
            end
            return unless target_idx
            abilities[target_idx]["uses_remaining"] = [ abilities[target_idx]["uses_remaining"].to_i + 1, abilities[target_idx]["uses_per_rest"].to_i ].min
            ctx.actor.update!(abilities: abilities)
            ctx.outcome[:triggered] ||= []
            ctx.outcome[:triggered] << { trigger: "restore_use", item_id: ctx.item&.id, ability: abilities[target_idx]["name"] }
          }
        },

        # Force a check to succeed once per rest (consumed). Resolver checks
        # for it on ability_use; if present + unconsumed, marks the outcome
        # critical_success and decrements uses on the item.
        "auto_succeed_check" => {
          phase:         :on_attack_roll,
          params_schema: {},
          apply: ->(ctx) {
            return unless ctx.item # item-only trigger (use-count lives on the row)
            uses_left = (ctx.item.properties || {}).dig("trigger_uses_remaining").to_i
            return unless uses_left.positive?
            ctx.outcome[:force_critical] = true
            new_props = (ctx.item.properties || {}).merge("trigger_uses_remaining" => uses_left - 1)
            ctx.item.update!(properties: new_props)
            ctx.outcome[:triggered] ||= []
            ctx.outcome[:triggered] << { trigger: "auto_succeed_check", item_id: ctx.item&.id }
          }
        }
      }.freeze

      class << self
        def known?(name)
          TRIGGERS.key?(name.to_s)
        end

        def lookup(name)
          TRIGGERS[name.to_s] or raise UnknownTrigger, "no trigger registered: #{name.inspect}"
        end

        # Validates that params satisfy the trigger's params_schema.
        # Used at YAML-load time; raises InvalidParams on shape mismatch.
        def validate_params!(name, params)
          schema = lookup(name)[:params_schema]
          schema.each do |key, expected|
            value = params[key.to_s] || params[key]
            allowed = Array(expected)
            unless allowed.any? { |klass| value.is_a?(klass) }
              raise InvalidParams, "trigger=#{name} param=#{key} must be one of #{allowed.inspect}; got #{value.class}"
            end
          end
        end

        # Fire all items' triggers for a given phase. Returns the outcome
        # hash (mutated in place by handlers).
        def fire_phase(phase:, actor:, target: nil, ability: nil, damage: nil, event_id: nil, outcome: {}, now: nil)
          return outcome unless PHASES.include?(phase)
          items_for(actor).each do |item|
            Array((item.properties || {})["effects"]).each do |effect|
              trig = TRIGGERS[effect["trigger"]]
              next unless trig && trig[:phase] == phase
              ctx = Context.new(
                actor:    actor,
                target:   target,
                item:     item,
                damage:   damage,
                ability:  ability,
                event_id: event_id,
                params:   effect["params"] || {},
                outcome:  outcome
              )
              trig[:apply].call(ctx)
            end
          end
          # Spell-borne effects (active_effects) fire through the SAME
          # registry — same entry shape, item: nil. Only consulted when the
          # caller passes the clock (`now`), since expiry is time-gated.
          if now
            ::Harness::Character::ActiveEffects.active_for(actor, now: now).each do |ae|
              Array(ae["effects"]).each do |effect|
                trig = TRIGGERS[effect["trigger"]]
                next unless trig && trig[:phase] == phase
                ctx = Context.new(
                  actor:    actor,
                  target:   target,
                  item:     nil,
                  damage:   damage,
                  ability:  ability,
                  event_id: event_id,
                  params:   effect["params"] || {},
                  outcome:  outcome
                )
                trig[:apply].call(ctx)
              end
            end
          end
          outcome
        end

        private

        def items_for(character)
          return [] unless character&.id
          ::Item.where(character_id: character.id).to_a
        end

        def damage_type_matches?(ctx)
          required = ctx.params["type"]
          return true if required.nil?
          ability_tags = Array(ctx.ability && ctx.ability["tags"])
          ability_tags.include?(required)
        end

        def target_has_tag?(target, tag)
          return false unless target
          return true if target.subrole.to_s == tag
          target_tags = Array(target.properties.is_a?(Hash) && target.properties["tags"])
          target_tags.include?(tag)
        end

        def destroy_item!(item)
          item.destroy
        end
      end
    end
  end
end
