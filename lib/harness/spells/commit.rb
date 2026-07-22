module Harness
  module Spells
    # The dumb half of composed magic. Takes a validated atom block (authored
    # in the library, cached on the ability, or fresh from the Composer) and
    # executes it in order against existing primitives — no reasoning, no LLM
    # judgment, no reordering. A bad atom is skipped with its error recorded;
    # a raising atom is rescued; the block can never crash a turn.
    #
    # Event posture (stage-2 ruling): the underlying tools' per-mutation logs
    # remain as audit rows (already excluded from Event.queryable / recall by
    # the mutation filter); the ONE composite narrative event appended at the
    # end is what the world remembers of the cast.
    module Commit
      class << self
        # atoms:     validated-shape atom array (re-validated per atom here —
        #            cached blocks replay long after composition)
        # narrative: one-line prose of what the cast visibly did (composer's,
        #            or nil → falls back to the spell description)
        # spell:     the ability hash being cast
        # caster:    Character actually casting
        # target:    bound present Character or nil
        # Returns { "records", "errors", "scene_dirty", "event_id" }.
        def run(atoms:, spell:, caster:, context:, target: nil, narrative: nil, logger: ::Rails.logger)
          state = { records: [], errors: [], scene_dirty: false, applied: [] }

          Array(atoms).first(Atoms::MAX_ATOMS).each_with_index do |atom, i|
            errs = Atoms.validate_atom(atom, i)
            if errs.any?
              state[:errors].concat(errs)
              next
            end
            result = begin
              execute(atom, spell: spell, caster: caster, target: target, context: context, state: state)
            rescue ::StandardError => e
              logger.warn { "[Spells::Commit] atom[#{i}] #{atom['kind']} raised: #{e.class}: #{e.message}" }
              { "error" => "#{atom['kind']} failed: #{e.message}" }
            end
            state[:records] << { "name" => "spell_#{atom['kind']}", "args" => atom, "result" => result }
            if result.is_a?(::Hash) && result["error"]
              state[:errors] << result["error"]
            else
              state[:applied] << atom["kind"]
            end
          end

          event = log_composite(spell, caster, target, narrative, state, context)
          logger.info do
            "[Spells::Commit] #{spell['id']}: applied #{state[:applied].join(',').presence || 'nothing'}" \
              "#{state[:errors].any? ? " errors=#{state[:errors].size}" : ''}"
          end

          {
            "records"     => state[:records],
            "errors"      => state[:errors],
            "scene_dirty" => state[:scene_dirty],
            "event_id"    => event&.id
          }
        end

        private

        def execute(atom, spell:, caster:, target:, context:, state:)
          case atom["kind"]
          when "damage"           then apply_damage(atom, caster, target)
          when "heal"             then apply_heal(atom, caster, target)
          when "timed_effect"     then apply_timed_effect(atom, spell, caster, target, context)
          when "mutate_character" then apply_mutate_character(atom, caster, target, context)
          when "mutate_item"      then apply_mutate_item(atom, caster, target, context)
          when "mint_item"        then apply_mint_item(atom, spell, caster, target, context)
          when "create_character" then apply_create_character(atom, spell, caster, context, state)
          when "create_location"  then apply_create_location(atom, spell, caster, context, state)
          when "alter_location"   then apply_alter_location(atom, caster, context)
          when "teleport"         then apply_teleport(atom, caster, target, context, state)
          when "follower"         then apply_follower(atom, caster, target, state)
          when "coins"            then apply_coins(atom, caster, target)
          when "write_knowledge"  then apply_write_knowledge(atom, caster, context)
          when "write_event"      then apply_write_event(atom, spell, caster, target, context)
          when "reprose"          then apply_reprose(atom, caster, target, context)
          when "advance_clock"    then apply_advance_clock(atom, spell, context)
          when "revive"           then apply_revive(atom, caster, target, state)
          end
        end

        def who_for(ref, caster, target)
          return caster if ref == "caster"
          target  # nil when unbound — callers error on it
        end

        def no_target
          { "error" => "atom addresses target but no target is bound" }
        end

        def apply_damage(atom, caster, target)
          who = who_for(atom["who"], caster, target) or return no_target
          rolled = ::Harness::Abilities::DiceFormula.roll(atom["dice"])
          new_hp = [ who.current_hp.to_i - rolled, 0 ].max
          attrs  = { current_hp: new_hp }
          killed = new_hp <= 0 && who.max_hp.to_i.positive?
          attrs[:properties] = (who.properties || {}).merge("stance" => "downed") if killed
          who.update!(attrs)
          dropped = []
          if killed && who.is_a?(::Npc)
            dropped = ::Harness::Items::Loot.drop_to_floor(who)
            props = who.reload.properties || {}
            who.update!(properties: props.except("following_player")) if props["following_player"]
          end
          { "damage" => rolled, "on" => who.name, "hp" => "#{new_hp}/#{who.max_hp}",
            "killed" => killed || nil,
            "dropped_items" => dropped.any? ? dropped.map(&:name) : nil }.compact
        end

        def apply_heal(atom, caster, target)
          who = who_for(atom["who"], caster, target) or return no_target
          rolled = ::Harness::Abilities::DiceFormula.roll(atom["dice"])
          new_hp = [ who.current_hp.to_i + rolled, who.max_hp.to_i ].min
          healed = new_hp - who.current_hp.to_i
          who.update!(current_hp: new_hp)
          { "healed" => healed, "on" => who.name, "hp" => "#{new_hp}/#{who.max_hp}" }
        end

        # Same store + refresh semantics as stage-1 spell effects: the
        # synthesized source id is stable per (spell, effect name), so a
        # recast refreshes rather than stacks.
        def apply_timed_effect(atom, spell, caster, target, context)
          who = who_for(atom["who"], caster, target) or return no_target
          slug = atom["name"].to_s.downcase.gsub(/\W+/, "_")
          entry = ::Harness::Character::ActiveEffects.apply!(
            who,
            ability: {
              "id"   => "#{spell['id']}:#{slug}",
              "name" => atom["name"],
              "effect" => {
                "duration_minutes" => atom["duration_minutes"],
                "modifiers"        => atom["modifiers"],
                "roll_modifier"    => atom["roll_modifier"],
                "effects"          => atom["effects"]
              }.compact
            },
            now: context.game_time
          )
          { "effect" => entry["name"], "on" => who.name, "expires_at" => entry["expires_at"] }
        end

        def apply_mutate_character(atom, caster, target, context)
          who = who_for(atom["who"], caster, target) or return no_target
          ::Harness::Tools::MutateCharacter.new.call(
            { "character_id" => who.id, "field" => atom["field"], "value" => atom["value"] }, context
          )
        end

        # Item lookup by name: the caster's inventory first, then the bound
        # target's, then loose items at the scene.
        def apply_mutate_item(atom, caster, target, context)
          n = atom["item"].to_s.downcase
          scopes = [ ::Item.where(character_id: caster.id) ]
          scopes << ::Item.where(character_id: target.id) if target
          scopes << ::Item.where(location_id: caster.location_id) if caster.location_id
          item = scopes.lazy.filter_map { |s| s.find { |i| i.name.to_s.downcase == n } }.first
          return { "error" => "no item named #{atom['item'].inspect} on caster, target, or scene" } unless item

          ::Harness::Tools::MutateItem.new.call(
            { "item_id" => item.id, "field" => atom["field"], "value" => atom["value"] }, context
          )
        end

        def apply_mint_item(atom, spell, caster, target, context)
          args = {
            "name"       => atom["name"],
            "subrole"    => atom["subrole"],
            "connection" => "wrought by the spell #{spell['name']}",
            "properties" => atom["properties"].is_a?(::Hash) ? atom["properties"] : {}
          }
          case atom["to"]
          when "caster" then args["character_id"] = caster.id
          when "target"
            return no_target unless target
            args["character_id"] = target.id
          else args["location_id"] = caster.location_id
          end
          ::Harness::Tools::ProposeItem.new.call(args, context)
        end

        # A being made real at the caster's location. `follow: true` binds it
        # as the caster's companion in the same stroke (the summon shape —
        # a separate follower atom can't reference a not-yet-existing being).
        def apply_create_character(atom, spell, caster, context, state)
          loc = caster.location
          return { "error" => "caster has no location to conjure into" } unless loc
          name = atom["name"].presence || ::Harness::Naming.unique_for(location: loc)
          props = { "physical" => atom["description"] }
          props["following_player"] = true if atom["follow"] && caster.is_a?(::Player)
          npc = ::Harness::Character::Hatchery.spawn(
            llm_grunt:     context.llm_grunt,
            name:          name,
            subrole:       atom["subrole"],
            location_id:   loc.id,
            properties:    props,
            prose_context: "conjured by the spell #{spell['name']}: #{atom['description']}"
          )
          state[:scene_dirty] = true
          { "character_id" => npc.id, "name" => npc.name, "subrole" => npc.subrole,
            "following" => props["following_player"] }.compact
        end

        def apply_create_location(atom, spell, caster, context, state)
          type = atom["type"] == "wilderness_leaf" ? "wilderness_leaf" : "sublocation"
          args = {
            "name"        => atom["name"],
            "description" => atom["description"],
            "type"        => type,
            "connection"  => "wrought by the spell #{spell['name']}"
          }
          args["parent_id"] = caster.location_id if type == "sublocation"
          result = ::Harness::Tools::ProposeLocation.new.call(args, context)
          state[:scene_dirty] = true unless result["error"]
          result
        end

        def apply_alter_location(atom, caster, context)
          return { "error" => "caster has no location to alter" } unless caster.location_id
          ::Harness::Tools::MutateLocation.new.call(
            { "location_id" => caster.location_id, "alteration" => atom["alteration"] }, context
          )
        end

        def apply_teleport(atom, caster, target, context, state)
          who = who_for(atom["who"], caster, target) or return no_target
          d = atom["destination"].to_s.strip
          dest = ::Location.find_by("LOWER(name) = ?", d.downcase) ||
                 ::Location.where("LOWER(name) LIKE ?", "%#{d.downcase}%").first
          return { "error" => "no location named #{atom['destination'].inspect} exists" } unless dest

          who.update!(location_id: dest.id)
          context.player_location = dest if who.is_a?(::Player)
          state[:scene_dirty] = true
          { "teleported" => who.name, "to" => dest.name }
        end

        def apply_follower(atom, caster, target, state)
          who = who_for(atom["who"], caster, target) or return no_target
          return { "error" => "the caster cannot follow themselves" } if who.id == caster.id
          return { "error" => "only NPCs can be bound as followers" } unless who.is_a?(::Npc)
          props = (who.properties || {}).dup
          if atom["attach"]
            props["following_player"] = true
          else
            props.delete("following_player")
          end
          who.update!(properties: props)
          state[:scene_dirty] = true
          { "follower" => who.name, "attached" => atom["attach"] }
        end

        def apply_coins(atom, caster, target)
          who = who_for(atom["who"], caster, target) or return no_target
          before = who.coins.to_i
          after  = [ before + atom["delta"], 0 ].max
          who.update!(coins: after)
          { "on" => who.name, "delta" => after - before, "coins" => after }
        end

        # A lasting truth planted in the world's standing memory, anchored at
        # the enclosing settlement (the same town-wide channel genesis lore
        # uses). Embedding is left nil for the ranker to backfill.
        def apply_write_knowledge(atom, caster, context)
          root = caster.location
          root = root.parent while root&.parent_id
          row = ::Knowledge.create!(
            content:     atom["content"],
            location_id: root&.id,
            current:     true,
            source_kind: "spell",
            speaker:     caster.name,
            game_time:   context.game_time
          )
          { "knowledge_id" => row.id }
        end

        def apply_write_event(atom, spell, caster, target, context)
          participants = Array(atom["who"]).filter_map do |ref|
            char = who_for(ref, caster, target)
            { character: char, role: "subject" } if char
          end
          event = ::Harness::Event::ForwardAppender.append(
            game_time: context.game_time,
            scope:     "personal",
            location:  caster.location,
            details:   { "narrative" => { "trigger" => "wrought by #{spell['name']}", "details" => atom["summary"] } },
            participants: participants
          )
          { "event_id" => event.id }
        end

        # Re-run the description materializer under a directive — appearance
        # and personality regenerate against the row's CURRENT stats, so
        # mutate_character atoms earlier in the block are already visible.
        def apply_reprose(atom, caster, target, context)
          who = who_for(atom["who"], caster, target) or return no_target
          return { "error" => "reprose needs an LLM tier and none is available" } unless context.llm_grunt
          return { "error" => "the player's description is not LLM territory" } if who.is_a?(::Player)
          ::Harness::Description::Materializer
            .new(llm_client: context.llm_grunt)
            .materialize!(who, prose_context: "remade by magic: #{atom['directive']}")
          { "reprosed" => who.name }
        end

        def apply_advance_clock(atom, spell, context)
          before = context.game_time
          ::Harness::Clock.advance(context, minutes: atom["minutes"], reason: "spell(#{spell['id']})")
          { "minutes" => atom["minutes"], "before" => before, "after" => context.game_time }
        end

        def apply_revive(atom, caster, target, state)
          who = who_for(atom["who"], caster, target) or return no_target
          return { "error" => "#{who.name} has no body to revive (uninitialized hp)" } unless who.max_hp.to_i.positive?
          hp = (atom["hp"].is_a?(::Integer) ? atom["hp"] : 1).clamp(1, who.max_hp)
          props = (who.properties || {}).dup
          props.delete("stance")
          who.update!(current_hp: hp, properties: props)
          state[:scene_dirty] = true
          { "revived" => who.name, "hp" => "#{hp}/#{who.max_hp}" }
        end

        def log_composite(spell, caster, target, narrative, state, context)
          participants = [ { character: caster, role: "actor" } ]
          participants << { character: target, role: "target" } if target
          ::Harness::Event::ForwardAppender.append(
            game_time: context.game_time,
            scope:     "personal",
            location:  caster.location,
            details: {
              "narrative" => {
                "trigger" => "cast #{spell['name']}",
                "details" => narrative.presence || spell["description"].to_s
              },
              "spell" => { "id" => spell["id"], "atoms" => state[:applied] }
            },
            participants: participants
          )
        rescue ::StandardError => e
          ::Rails.logger.warn { "[Spells::Commit] composite event failed: #{e.class}: #{e.message}" }
          nil
        end
      end
    end
  end
end
