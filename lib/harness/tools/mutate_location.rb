module Harness
  module Tools
    # Record a PERSISTENT change to a location's physical state — a door
    # barricaded, a bridge collapsed, a wall breached, a fire set. Deliberately
    # narrow: it APPENDS a short alteration note to `location.properties.
    # alterations` (and logs an event); it does NOT rewrite the base
    # description. That keeps environment changes durable and queryable while
    # avoiding the description-drift the LLM would cause with free rewrites.
    #
    # Props (scene furniture) stay ephemeral as ever — this is only for changes
    # that should OUTLAST the scene and surface in future scene assembly. Does
    # NOT set scene_dirty: the change persists in the location row and shows on
    # the NEXT assembly; this turn's narration renders it from the tool result.
    # (We don't rebuild the scene just to reflect it — that's the whiplash we
    # removed.)
    class MutateLocation < Base
      MAX_ALTERATIONS = 25

      def self.tool_name
        "mutate_location"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Record a PERSISTENT physical change to a location — a door barred, a wall breached, a bridge down, a fire set. Appends a short alteration note that persists across scenes and surfaces in later scene assembly. Use ONLY for changes that should outlast the current scene; ephemeral/cosmetic effects stay in narration. Does not rewrite the location's base description. Logs a local-scope event.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "location_id" => { "type" => "integer", "description" => "the location being changed (usually the current scene)" },
              "alteration"  => { "type" => "string", "description" => "short prose of the persistent change, e.g. 'the north door is barricaded'" }
            },
            "required" => [ "location_id", "alteration" ]
          }
        }
      end

      def call(args, context)
        id         = args["location_id"]
        alteration = args["alteration"]

        return { "error" => "location_id required" } if id.nil?
        return { "error" => "alteration must be a non-empty string" } unless alteration.is_a?(String) && !alteration.strip.empty?

        loc = ::Location.find_by(id: id)
        return { "error" => "no location with id=#{id}" } unless loc

        note  = alteration.strip
        props = (loc.properties || {}).dup
        alts  = Array(props["alterations"]) + [ note ]
        alts  = alts.last(MAX_ALTERATIONS)
        props["alterations"] = alts
        loc.update!(properties: props)

        log_event(loc, note, context)
        { "id" => loc.id, "alteration" => note, "alterations" => alts }
      end

      private

      def log_event(loc, note, context)
        player = ::Player.first
        participants = player ? [ { character: player, role: "actor" } ] : []
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "local",
          location:  loc,
          details: {
            "mutation" => {
              "target_type" => "location",
              "target_id"   => loc.id,
              "alteration"  => note
            }
          },
          participants: participants
        )
      end
    end
  end
end
