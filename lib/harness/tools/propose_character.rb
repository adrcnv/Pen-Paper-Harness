module Harness
  module Tools
    # Instantiate a new NPC at runtime. The LLM uses this when narrative demands
    # a character who isn't yet in the store — a courier shows up, a stranger
    # walks in, the cousin from the next village is mentioned for the first time.
    #
    # `connection` is a free-text rationale tying the new character to something
    # already in the store (an existing character, faction, recent event, or
    # scene-level dynamic). It's recorded in the introduction event's details
    # for posterity. Per-scene caps and density limits are NOT enforced here yet —
    # that's the Pacing layer's job (not built).
    class ProposeCharacter < Base
      def self.tool_name
        "propose_character"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Create a new NPC and place them at a location. `connection` is a short free-text rationale grounding the new character in existing state (e.g., a relative of an existing NPC, a recruit answering a faction's call). Defaults location to the current scene. `properties` is an optional JSON object — typical fields are `personality` (one-line disposition), `physical` (one-line appearance: build, age, distinguishing features), `mood` (current baseline), `faction_id`. If you are materializing an ambient figure already painted into the scene by `present_extras`, pass `from_extra` with the EXACT description string from that list — the extra is then removed so it doesn't double-render alongside the new character. Logs a personal-scope introduction event. NAME COLLISIONS: if a character matching this name (exact or first-token, case-insensitive) already exists at this location's city ancestry, the call returns an `existing_character` object — use mutate_character to relocate/update them instead of creating a duplicate, OR pick a more distinct name.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "name"        => { "type" => "string", "description" => "character's display name" },
              "subrole"     => { "type" => "string", "description" => "archetype: barkeep, guard, smith, courier, ..." },
              "connection"  => { "type" => "string", "description" => "free-text rationale linking to existing state" },
              "location_id" => { "type" => "integer", "description" => "optional; defaults to the current scene location" },
              "properties"  => { "type" => "object", "description" => "optional initial properties. Typical fields: personality (one-line disposition), physical (one-line appearance), mood (current baseline), faction_id" },
              "from_extra"  => { "type" => "string", "description" => "OPTIONAL. EXACT description string from query_scene's `present_extras` list. If provided, removes that extra from the active scene so it doesn't render twice." }
            },
            "required" => [ "name", "subrole", "connection" ]
          }
        }
      end

      def call(args, context)
        name       = args["name"]
        subrole    = args["subrole"]
        connection = args["connection"]
        location_id = args["location_id"]
        properties = args["properties"] || {}
        from_extra = args["from_extra"]

        return { "error" => "name must be a non-empty string" } unless name.is_a?(String) && !name.strip.empty?
        return { "error" => "subrole must be a non-empty string" } unless subrole.is_a?(String) && !subrole.strip.empty?
        return { "error" => "connection must be a non-empty string" } unless connection.is_a?(String) && !connection.strip.empty?
        return { "error" => "properties must be an object" } unless properties.is_a?(Hash)

        if from_extra
          return { "error" => "from_extra must be a string" } unless from_extra.is_a?(String)
          active = context.active_scene
          return { "error" => "no active scene — cannot promote an extra" } unless active
          extras = active.extras || []
          unless extras.include?(from_extra)
            return { "error" => "no extra matches #{from_extra.inspect}; current extras: #{extras.inspect}" }
          end
          extras.delete(from_extra)
        end

        location = if location_id
          loc = ::Location.find_by(id: location_id)
          return { "error" => "no location with id=#{location_id}" } unless loc
          loc
        else
          context.player_location
        end

        if (existing = find_name_collision(name, location))
          return {
            "error" => "name collision: an existing character at this location's ancestry shares this name. If you intended this same person, use mutate_character to update their properties (and possibly relocate them) — do NOT create a duplicate. If they're a different person, propose with a more specific name (e.g., 'Marta the Younger', 'Marta of the Hearth').",
            "existing_character" => {
              "character_id"  => existing.id,
              "name"          => existing.name,
              "subrole"       => existing.subrole,
              "location_id"   => existing.location_id,
              "location_name" => existing.location&.name
            }
          }
        end

        npc = ::Harness::Character::Hatchery.spawn(
          llm_grunt:     context.llm_grunt,
          name:          name,
          subrole:       subrole,
          location:      location,
          # A proposed character belongs where they're placed — if it's a
          # residence (a settlement, or a lair). Promoted extras and
          # worldbuilding NPCs in a town or a bandit lair get a home; one
          # created at a social waypoint / open wild stays homeless.
          home_location_id: (location.residence? ? location.id : nil),
          properties:    properties,
          prose_context: connection
        )

        # Two payloads in one event: `introduction` for audit (excluded from
        # BackwardAppender's floor check so backstory committing stays open),
        # `narrative` for NPC-speech sourcing (the connection prose is the new
        # character's structural reason-for-existing — query_events surfaces
        # it via the queryable scope so the new NPC can speak about why they're
        # here).
        event = ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  location,
          details: {
            "introduction" => {
              "target_type" => "character",
              "target_id"   => npc.id,
              "target_name" => npc.name,
              "subrole"     => npc.subrole,
              "connection"  => connection
            },
            "narrative" => {
              "trigger" => "introduced as #{npc.subrole}",
              "details" => connection
            }
          },
          participants: [ { character: npc, role: "subject" } ]
        )

        {
          "character_id"      => npc.id,
          "name"              => npc.name,
          "subrole"           => npc.subrole,
          "location_id"       => npc.location_id,
          "event_id"          => event.id,
          "game_time"         => context.game_time,
          "committed_summary" => "[committed character_id=#{npc.id}] #{npc.name} (#{npc.subrole}) at location_id=#{npc.location_id} — #{connection.to_s[0, 100]}"
        }
      end

      private

      # Name collision detection across the location's ancestry. Catches both
      # exact matches ("Marta" vs "Marta") and first-token overlaps ("Marta"
      # vs "Marta of the Moss" — the canonical Genesis-vs-propose collision
      # the class-2 retirement was supposed to fix). LLM gets the existing
      # character back so it can decide: relocate the existing one, or pick a
      # more distinct name.
      def find_name_collision(proposed_name, location)
        ancestry_ids = location_ancestry_ids(location)
        ::Npc.where(location_id: ancestry_ids).find { |c| name_match?(c.name, proposed_name) }
      end

      def location_ancestry_ids(location)
        root = location
        root = root.parent while root.parent
        [ root.id ] + descendant_ids(root)
      end

      def descendant_ids(loc)
        children = ::Location.where(parent_id: loc.id).to_a
        children.map(&:id) + children.flat_map { |c| descendant_ids(c) }
      end

      def name_match?(a, b)
        a_norm = a.to_s.strip.downcase
        b_norm = b.to_s.strip.downcase
        return false if a_norm.empty? || b_norm.empty?
        return true  if a_norm == b_norm
        return true  if a_norm == b_norm.split(/\s+/).first
        return true  if b_norm == a_norm.split(/\s+/).first
        false
      end
    end
  end
end
