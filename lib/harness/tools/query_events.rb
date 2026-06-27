module Harness
  module Tools
    # Search the event log. Three modes:
    #
    # 1. AUDIT (no for_holder_id) — unfiltered view of the world's record.
    #    Use for META checks: did the disclosure get committed? what events
    #    involve this place? did this past fact get logged yet?
    #
    # 2. NPC SOURCE (for_holder_id set) — events the holder could plausibly
    #    know about: events they participated in, PLUS regional+/kingdom/world
    #    scope events, PLUS local-scope events at their current location (locals
    #    hear about local happenings — the SHARE discovery widening). This is the
    #    canonical "what does this NPC know" path, replacing query_beliefs.
    #    Knowing is not telling — divulging stays gated in the conversation
    #    prompt (public freely, sensitive behind a check).
    #
    # 3. SUPPLEMENT LOOKUP (references_event_id set) — return events that
    #    elaborate on a prior event without modifying it. See ProposeEvent's
    #    references_event_id arg.
    #
    # All filters compose: for_holder_id + location_id + min_game_time, etc.
    class QueryEvents < Base
      DEFAULT_LIMIT = 20
      MAX_LIMIT     = 100
      PROJECTING_SCOPES = (::Event::ALLOWED_SCOPES - %w[personal local]).freeze

      def self.tool_name
        "query_events"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Search the event log. Filter by `for_holder_id` to get events an NPC could plausibly know (events they participated in + regional+/kingdom/world public events + local events at their current location) — this is the canonical 'what does this NPC know' path. Without `for_holder_id`, returns the unfiltered audit view (META checks). Other filters compose: character_id (events involving this character), location_id, min/max_game_time, scope, references_event_id (supplements). Returns newest-first, up to `limit` (default 20, max 100).",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "for_holder_id"        => { "type" => "integer", "description" => "Return events this character could plausibly KNOW about: events they directly participated in PLUS regional+/kingdom/world-scope public events PLUS local-scope events at their current location. Use for sourcing NPC speech." },
              "character_id"         => { "type" => "integer", "description" => "Events this character was a participant in (no scope projection — direct participation only). Differs from for_holder_id which also includes public-scope events." },
              "location_id"          => { "type" => "integer", "description" => "Events at this location." },
              "min_game_time"        => { "type" => "integer", "description" => "Inclusive lower bound on game_time." },
              "max_game_time"        => { "type" => "integer", "description" => "Inclusive upper bound on game_time." },
              "scope"                => { "type" => "string",  "description" => "One of personal/local/regional/kingdom/world." },
              "references_event_id"  => { "type" => "integer", "description" => "Return events whose `references_event_id` points at this id — supplements that elaborate on the original." },
              "limit"                => { "type" => "integer", "description" => "Max rows returned (default 20, max 100)." }
            },
            "required" => []
          }
        }
      end

      def call(args, _context)
        scope = ::Event.queryable
        scope = scope.where(location_id: args["location_id"]) if args["location_id"]
        scope = scope.where("game_time >= ?", args["min_game_time"]) if args["min_game_time"]
        scope = scope.where("game_time <= ?", args["max_game_time"]) if args["max_game_time"]
        scope = scope.where(scope: args["scope"]) if args["scope"]
        scope = scope.where(references_event_id: args["references_event_id"]) if args["references_event_id"]

        if args["character_id"]
          participant_scope = ::EventParticipant.where(character_id: args["character_id"])
          scope = scope.joins(:event_participants).merge(participant_scope).distinct
        end

        if (holder_id = args["for_holder_id"])
          holder = ::Character.find_by(id: holder_id)
          return { "error" => "no character with id=#{holder_id}" } unless holder
          ids = ids_for_holder(holder)
          scope = scope.where(id: ids)
        end

        limit = (args["limit"] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
        events = scope.order(game_time: :desc, id: :desc).limit(limit).includes(:event_participants)

        {
          "events" => events.map { |e| event_hash(e) }
        }
      end

      private

      # The "what could this character plausibly know" filter — direct
      # participation + scope projection. Mirrors what the deprecated
      # Belief::PreFilter did, surfaced as a tool argument now that there's
      # no separate belief read path.
      def ids_for_holder(holder)
        participant_ids = ::EventParticipant.where(character_id: holder.id).pluck(:event_id)
        scope_ids       = ::Event.where(scope: PROJECTING_SCOPES).pluck(:id)
        local_ids       = local_knowledge_ids(holder)
        participant_ids | scope_ids | local_ids
      end

      # SHARE — widen "knowing": a `local`-scope event at a place is, by the
      # meaning of the scope, known to people THERE, not only its direct
      # participants. So a holder also knows local events at their current
      # location. This is the discovery-surface engine — ask around at the
      # destination and the locals know what happened there (including a claimed
      # person's arrival, which SocialWeb writes as local awareness events).
      #
      # Widens KNOWING only. Whether the NPC DIVULGES stays gated by the
      # conversation prompt (public history shared freely, sensitive behind a
      # resolve check) — knowing is not telling. Newest-first + the query limit
      # bound the volume; nothing is pushed or stored.
      def local_knowledge_ids(holder)
        loc_id = holder.location_id
        return [] unless loc_id
        ::Event.where(scope: "local", location_id: loc_id).pluck(:id)
      end

      def event_hash(e)
        {
          "id"                   => e.id,
          "game_time"            => e.game_time,
          "scope"                => e.scope,
          "location_id"          => e.location_id,
          "details"              => e.details,
          "references_event_id"  => e.references_event_id,
          "participants"         => e.event_participants.map { |p|
            {
              "character_id" => p.character_id,
              "role"         => p.role
            }
          }
        }.compact
      end
    end
  end
end
