module Harness
  module Tools
    # Instantiate a new Faction at runtime. Used when narrative reveals an
    # organization that wasn't previously in the store — a thieves' guild a
    # patron mentions, a trade league the merchant works for, a cult someone
    # accuses the prisoner of belonging to.
    #
    # Faction events are logged at the current scene's location with no
    # participant (factions don't have character_ids), since the structural
    # tie from event → faction goes through prose in `details`.
    class ProposeFaction < Base
      def self.tool_name
        "propose_faction"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Create a new faction. `is_kingdom` distinguishes territorial states (kingdoms, empires, trade leagues with realm-scale claims) from organizations (guilds, cults, mercenary companies). `connection` is a short free-text rationale grounding the faction in existing state. Logs a local-scope introduction event at the current scene with no participant.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "name"        => { "type" => "string", "description" => "faction's display name" },
              "subrole"     => { "type" => "string", "description" => "archetype: thieves_guild, merchants_guild, kingdom, cult, ..." },
              "is_kingdom"  => { "type" => "boolean", "description" => "true for territorial/realm-scale factions; default false" },
              "connection"  => { "type" => "string", "description" => "free-text rationale linking to existing state" },
              "properties"  => { "type" => "object", "description" => "optional initial properties (disposition, reach, notable_members, ...)" }
            },
            "required" => [ "name", "subrole", "connection" ]
          }
        }
      end

      def call(args, context)
        name       = args["name"]
        subrole    = args["subrole"]
        connection = args["connection"]
        is_kingdom = args["is_kingdom"]
        properties = args["properties"] || {}

        return { "error" => "name must be a non-empty string" } unless name.is_a?(String) && !name.strip.empty?
        return { "error" => "subrole must be a non-empty string" } unless subrole.is_a?(String) && !subrole.strip.empty?
        return { "error" => "connection must be a non-empty string" } unless connection.is_a?(String) && !connection.strip.empty?
        return { "error" => "properties must be an object" } unless properties.is_a?(Hash)
        unless is_kingdom.nil? || is_kingdom == true || is_kingdom == false
          return { "error" => "is_kingdom must be boolean" }
        end

        faction = ::Faction.create!(
          name:       name,
          subrole:    subrole,
          is_kingdom: !!is_kingdom,
          properties: properties
        )

        event = ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "local",
          location:  context.player_location,
          details: {
            "introduction" => {
              "target_type" => "faction",
              "target_id"   => faction.id,
              "target_name" => faction.name,
              "subrole"     => faction.subrole,
              "is_kingdom"  => faction.is_kingdom,
              "connection"  => connection
            },
            # Surfaced via Event.queryable for NPC speech sourcing — see
            # propose_character for the rationale.
            "narrative" => {
              "trigger" => "introduced #{faction.subrole}",
              "details" => connection
            }
          },
          participants: []
        )

        {
          "faction_id"        => faction.id,
          "name"              => faction.name,
          "subrole"           => faction.subrole,
          "is_kingdom"        => faction.is_kingdom,
          "event_id"          => event.id,
          "game_time"         => context.game_time,
          "committed_summary" => "[committed faction_id=#{faction.id}] #{faction.name} (#{faction.subrole}#{faction.is_kingdom ? ', kingdom' : ''})"
        }
      end
    end
  end
end
