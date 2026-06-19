module Harness
  module Tools
    class QueryScene < Base
      def self.tool_name
        "query_scene"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Return the current scene: current location, parent location, sibling sublocations, child sublocations (places INSIDE this one), present characters (alive only), present_corpses (dead bodies still on the floor — inert; not action targets, but available for narration flavor and `transfer_coins` looting from the corpse), present items, and present_extras (ambient nameless figures painted into the scene — narration flavor only, NO ids). Any of `parent`, `siblings`, or `children` is a valid `transition` target (intra-city movement). For inter-city travel between top-level locations, use `query_location_by_name` to resolve a destination, then call `travel`. If the player engages an extra consequentially, call propose_character to materialize them (the description carries forward via the connection arg). Always available.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {},
            "required"   => []
          }
        }
      end

      def call(_args, context)
        self.class.build(context)
      end

      # Class-method form used both by the tool call and by Turn::Loop to
      # pre-inject scene state into the reasoning prompt (so the model
      # doesn't need to spend a round-trip on a defensive query_scene call
      # at the start of every turn — see INPUT.scene in the reasoning
      # prompt).
      #
      # `condense_mood:` when true, internal_state prose is suppressed from
      # each present_character entry. Caller passes true on turns where the
      # scene has already produced narration this scene — the model has
      # already seen the mood line via prior turns and doesn't need it
      # re-read every iteration. (Mood may also have drifted from the cached
      # scene-entry snapshot; narration's no-invention rule already wants the
      # model to render from this-turn's tool results, not from the cached
      # mood.) See AUDIT in execution_flows_observed.md.
      def self.build(context, condense_mood: false)
        snap = ::Harness::Scene::Assembler.for(location: context.player_location)
        active = context.active_scene
        # If the player moved mid-turn (transition / travel), the cached active
        # scene belongs to the OLD location — its extras / internal_state /
        # agendas would leak into a query for the new place. Drop the active
        # ref in that case; the new scene's flavor will materialize on the
        # next Manager.enter.
        active = nil if active && active.location.id != context.player_location.id
        loc    = snap.location

        siblings = if loc.parent_id
          ::Location.where(parent_id: loc.parent_id).where.not(id: loc.id).map { |s|
            { "id" => s.id, "name" => s.name }
          }
        else
          []
        end

        children = ::Location.where(parent_id: loc.id).map { |c|
          { "id" => c.id, "name" => c.name, "description" => c.description }
        }

        {
          "location" => {
            "id"             => loc.id,
            "name"           => loc.name,
            "description"    => loc.description,
            # Surfaces wilderness_leaf encounter context. Combat encounters
            # mean the present NPCs are hostile; see the ENCOUNTER SCENES
            # section in the reasoning prompt.
            "encounter_type" => loc.properties.is_a?(Hash) ? loc.properties["encounter_type"] : nil
          }.compact,
          "parent"   => loc.parent ? { "id" => loc.parent.id, "name" => loc.parent.name } : nil,
          "siblings" => siblings,
          "children" => children,
          "present_characters" => snap.present_characters.map { |c|
            entry = { "id" => c.id, "name" => c.name, "subrole" => c.subrole }
            # Surface gender so the reasoning loop and narration use the right
            # pronouns instead of re-guessing from an ambiguous name each turn.
            # Grounded once at spawn (Hatchery), authoritative over the name.
            if c.properties.is_a?(Hash) && c.properties["gender"]
              entry["gender"] = c.properties["gender"]
            end
            # Surface the follower flag so the reasoning loop knows allegiance
            # at-a-glance. A follower is the player's structural ally and
            # should act on their behalf in combat — see the FOLLOWERS rule
            # in the reasoning prompt.
            if c.properties.is_a?(Hash) && c.properties["following_player"] == true
              entry["following_player"] = true
            end
            # Surface the interpretation lens so the reasoning loop can color
            # this NPC's voice and stance when sourcing speech — see NPC VOICE
            # in the reasoning prompt. `balanced` is the default majority and
            # gets surfaced explicitly for legibility.
            if c.properties.is_a?(Hash) && c.properties["lens"]
              entry["lens"] = c.properties["lens"]
            end
            # Compact ability surface: name + uses_remaining for each ability
            # the NPC has. Saves a query_character round-trip during combat
            # (the LLM picks an ability_name straight from this list). Cost
            # is small — most NPCs have 1-3 abilities. Empty list = unarmed
            # (the hardcoded `unarmed_strike` 1d4 fallback always works).
            abilities = Array(c.abilities)
            entry["abilities"] = abilities.map { |a| { "name" => a["name"], "uses_remaining" => a["uses_remaining"] } } if abilities.any?
            unless condense_mood
              state = active&.state_for(c.id)
              entry["internal_state"] = state if state
            end
            agenda = active&.agenda_for(c.id)
            if agenda
              # Collapsed shape: `agenda: { text:, push_now: }`.
              # push_now=true means the NPC has gone N+ turns silent and the
              # system wants a beat THIS turn regardless of player input
              # opening. See the AGENDAS rule in the reasoning prompt.
              entry["agenda"] = {
                "text"     => agenda,
                "push_now" => active&.agenda_overdue?(c.id) || false
              }
            end
            entry
          },
          "present_items" => snap.present_items.map { |i|
            { "id" => i.id, "name" => i.name }
          },
          # Dead bodies still anchored here. Inert as `resolve` targets
          # (resolve rejects them with `target is dead`); kept narratable so
          # the LLM can describe the body and surface looting hooks
          # (`transfer_coins` from the corpse, dropped items appear in
          # present_items via Loot.drop_to_floor at the kill).
          "present_corpses" => (snap.present_corpses || []).map { |c|
            { "id" => c.id, "name" => c.name }
          },
          # Ambient nameless figures from InternalState generation. Pure
          # flavor; no ids; cannot be commit targets. Narration may describe
          # them; reasoning loop must propose_character before committing
          # anything about them.
          "present_extras" => (active&.present_extras || []),
          # Combat-aware payload — only present when scene.in_combat?. Gives
          # the reasoning loop tactical visibility: round number, your slot
          # state, allies/hostiles with HP+position+engagement. See
          # COMBAT MODE in the reasoning prompt.
          "combat" => combat_payload(active)
        }.compact
      end

      def self.combat_payload(active)
        return nil unless active&.in_combat?
        state = active.combat
        player = ::Player.first
        player_id = player&.id

        members = state.sides.keys.map { |id| [ id, ::Character.find_by(id: id) ] }.to_h
        allies, hostiles = [], []
        player_side = player_id && state.side_of(player_id)
        state.sides.each do |cid, side_name|
          next if cid == player_id
          char = members[cid]
          next unless char
          next if char.max_hp.to_i > 0 && char.current_hp.to_i <= 0
          row = {
            "id"           => char.id,
            "name"         => char.name,
            "position"     => state.position_of(char.id),
            "hp"           => "#{char.current_hp}/#{char.max_hp}",
            "engaged_with" => state.engaged_with_of(char.id)
          }
          (side_name == player_side ? allies : hostiles) << row
        end

        current_id = state.current_actor_id
        current = members[current_id] || (current_id == player_id ? player : nil)

        payload = {
          "round"            => state.round,
          "current_actor"    => current ? { "id" => current.id, "name" => current.name } : nil,
          "initiative"       => state.initiative,
          "your_position"    => player_id ? state.position_of(player_id) : nil,
          "your_engaged_with" => player_id ? state.engaged_with_of(player_id) : nil,
          "your_action_spent" => player_id ? state.acted?(player_id) : false,
          "your_move_spent"   => player_id ? state.moved?(player_id) : false,
          "allies"           => allies,
          "hostiles"         => hostiles,
          "last_round_summary" => state.last_round_summary
        }
        payload.compact
      end
    end
  end
end
