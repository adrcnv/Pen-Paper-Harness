module Harness
  module Tools
    # Append a non-mechanical event to the log. Two modes:
    #
    # 1. FORWARD (default) — the event happened just now. game_time omitted.
    #    Append to current time, advance the clock by 1.
    #
    # 2. BACKWARD — the event happened in the PAST (narrative shift). Pass
    #    `game_time` < context.game_time. The backward-append pipe runs:
    #      * Floor check: each participant's earliest existing event game_time
    #        sets a floor. proposed game_time must be ≥ floor (you can't have
    #        someone act before they existed).
    #      * Pre-filter: events strictly after proposed game_time, narrowed to
    #        location-ancestor + participants.
    #      * Validator (grunt-tier LLM): judges contradictions against the
    #        after-set. Pure validator — accept or reject, no logical retry.
    #      * On contradiction: returns {error:, contradictions: [...]}; on
    #        floor violation: returns {error:}; the LLM decides what to do
    #        (rephrase or drop).
    #
    # Mechanical actions (anything resolved by a stat check) go through
    # `resolve` instead — backward-append does not exist for stat checks.
    class ProposeEvent < Base
      VALID_SCOPES = ::Event::ALLOWED_SCOPES
      PENDING_APPEARANCE_SCOPES = ::PendingAppearance::ALLOWED_SCOPES

      def self.tool_name
        "propose_event"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Append a narrative event that should persist past the current scene — promises, threats, arrivals, departures, secrets revealed, witnessed crimes, decisions with consequence. Do NOT use for flavor (walking, looking, ordering a drink); narration carries those. FORWARD mode: omit game_time, event happens now. BACKWARD mode (NARRATIVE SHIFT): pass game_time < current scene time to invent a past fact. Backward mode validates against later events. Scope: personal/local/regional/kingdom/world. Every participant MUST be a character_id pointing at an existing Character row — class-2 (actor_name) participants are retired; call propose_character first if a named figure needs to be introduced. Defaults location to current scene. Attach `creates_pending_appearance` to schedule a future consequence.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "scope"        => { "type" => "string", "enum" => VALID_SCOPES, "description" => "event scope tag" },
              "participants" => {
                "type"  => "array",
                "items" => {
                  "type"       => "object",
                  "properties" => {
                    "character_id" => { "type" => "integer", "description" => "Existing character row id. REQUIRED for every participant — there is no actor_name fallback." },
                    "role"         => { "type" => "string",  "description" => "free-text role (actor, victim, witness, accomplice, founder, ...)" }
                  },
                  "required" => [ "character_id", "role" ]
                },
                "description" => "Participants. Include the actor AND any witnesses — observers form a structural record of what they saw, which downstream query_events(for_holder_id=...) surfaces. The player's character_id is in INPUT.player; tag the player when they're the actor. Unnamed crowd ('a guard', 'two bandits') stays in details prose, NOT here. Class-2 actor_name strings are retired — every named figure must be a class-4 row first (use propose_character to introduce them)."
              },
              "trigger"     => { "type" => "string", "description" => "short prose describing what triggered the event (2-10 words)" },
              "details"     => { "type" => "string", "description" => "longer prose describing the event in narrative terms" },
              "location_id" => { "type" => "integer", "description" => "optional location override; defaults to current scene" },
              "game_time"   => { "type" => "integer", "description" => "OPTIONAL. Omit for forward-append (event happens now). Set to a value LESS than current game_time to backward-append (narrative shift inventing a past event). Backward mode triggers contradiction validation against later events." },
              "time_minutes" => { "type" => "integer", "description" => "FORWARD MODE ONLY: in-fiction minutes this event occupies. Defaults to 1 if omitted. Set higher for events that span time (a long story = 30, a heated argument = 15, a quiet shared meal = 45). Ignored in backward mode (past events don't advance the current clock)." },
              "references_event_id" => { "type" => "integer", "description" => "OPTIONAL. Mark this event as a SUPPLEMENT elaborating on an existing event without modifying it (events are append-only). Both events live and are returned together by query_events(references_event_id=<original>). Use when an NPC reveals new detail about a prior event, when a witness/participant needs to be added to a committed event, or when a consequence becomes visible later. Don't use to invent contradictions to a prior event — that's a backward propose_event with full validation." },
              "creates_pending_appearance" => {
                "type" => "object",
                "description" => "OPTIONAL. Schedule a future arrival because of THIS event — a wronged party, a debt collector, a faction emissary. Fires the next time the target is at a matching scope/location at-or-after earliest_at.",
                "properties" => {
                  "target_character_id" => { "type" => "integer", "description" => "Whose scene the arrival fires into. Usually the player (INPUT.player.id)." },
                  "intent_text"         => { "type" => "string",  "description" => "One-sentence prose describing what they want ('demands repayment of the dead merchant\\'s debt'). Surfaces in their internal-state on arrival." },
                  "scope"               => { "type" => "string", "enum" => PENDING_APPEARANCE_SCOPES, "description" => "local=anchor only; city=anchor + sublocations of same city; anywhere=any location. Default: city." },
                  "earliest_at_offset_minutes" => { "type" => "integer", "description" => "Minutes until firable. Default 60. Use 1440 (day) for slow-burn, 5-30 for immediate followups." },
                  "anchor_location_id"  => { "type" => "integer", "description" => "Where the consequence lives. Defaults to this event's location." },
                  "actor_character_id"  => { "type" => "integer", "description" => "Specific existing character who shows up. Mutually exclusive with faction-only mode (origin_faction_id)." },
                  "origin_character_id" => { "type" => "integer", "description" => "OPTIONAL. The character behind the arrival if known. Mutually exclusive with origin_faction_id." },
                  "origin_faction_id"   => { "type" => "integer", "description" => "REQUIRED for faceless mode (no actor specifier). Spawns a fresh faction member at fire time. Mutually exclusive with origin_character_id." }
                },
                "required" => [ "target_character_id", "intent_text" ]
              }
            },
            "required" => [ "scope", "trigger" ]
          }
        }
      end

      def call(args, context)
        scope                = args["scope"]
        trigger              = args["trigger"]
        details              = args["details"]
        participants         = args["participants"] || []
        location_id          = args["location_id"]
        proposed_gt          = args["game_time"]
        references_event_id  = args["references_event_id"]

        return { "error" => "scope must be one of: #{VALID_SCOPES.join(', ')}" } unless VALID_SCOPES.include?(scope)
        return { "error" => "trigger must be a non-empty string" } unless trigger.is_a?(String) && !trigger.strip.empty?
        return { "error" => "participants must be an array" } unless participants.is_a?(Array)

        if references_event_id
          unless references_event_id.is_a?(Integer) && ::Event.exists?(id: references_event_id)
            return { "error" => "references_event_id #{references_event_id.inspect} does not match an existing event" }
          end
        end

        location = if location_id
          loc = ::Location.find_by(id: location_id)
          return { "error" => "no location with id=#{location_id}" } unless loc
          loc
        else
          context.player_location
        end

        resolved_participants = []
        participants.each_with_index do |p, i|
          unless p.is_a?(Hash)
            return { "error" => "participants[#{i}] must be an object with character_id and role" }
          end
          char_id    = p["character_id"]
          actor_name = p["actor_name"]
          role       = p["role"]

          return { "error" => "participants[#{i}].role must be a non-empty string" } unless role.is_a?(String) && !role.strip.empty?

          # Phase 2: class-2 (actor_name string) participants are retired.
          # Every participant must point at an existing Character row.
          if actor_name && !actor_name.to_s.strip.empty?
            return {
              "error" => "participants[#{i}].actor_name is no longer supported — class-2 strings retired post-Phase-2. To name a historical figure, call propose_character first (creating a real Character row), then pass that character_id here. To leave the figure unnamed, drop them from participants and put their description in `details` prose instead."
            }
          end

          unless char_id.is_a?(Integer)
            return { "error" => "participants[#{i}].character_id must be an integer (got #{char_id.inspect})" }
          end

          char = ::Character.find_by(id: char_id)
          return { "error" => "participants[#{i}]: no character with id=#{char_id}" } unless char
          resolved_participants << { character: char, role: role }
        end

        details_payload = {
          "narrative" => { "trigger" => trigger, "details" => details }
        }

        # Mode-decision logging — without this, "why did this end up forward at
        # game_time=100003?" requires inferring from result fields. Log the
        # decision explicitly: what came in, what the current scene clock is,
        # which mode fired, and (if forward was chosen against an apparent
        # backward intent) why.
        current_gt    = context.game_time || 0
        gt_present    = proposed_gt.is_a?(Integer)
        backward_mode = gt_present && proposed_gt < current_gt

        mode_reason = if backward_mode
          "backward (proposed=#{proposed_gt} < current=#{current_gt})"
        elsif !gt_present
          "forward (no game_time supplied)"
        elsif proposed_gt == current_gt
          "forward (proposed=#{proposed_gt} == current=#{current_gt}; backward requires strictly less)"
        else
          "forward (proposed=#{proposed_gt} > current=#{current_gt}; backward requires past)"
        end
        ::Rails.logger.info { "[propose_event] mode=#{mode_reason} trigger=#{trigger.inspect}" }

        result = if backward_mode
          backward_append(
            context:             context,
            game_time:           proposed_gt,
            scope:               scope,
            location:            location,
            details:             details_payload,
            participants:        resolved_participants,
            references_event_id: references_event_id
          )
        else
          time_minutes = args["time_minutes"].is_a?(Integer) && args["time_minutes"] >= 0 ? args["time_minutes"] : 1
          forward_append(
            context:             context,
            scope:               scope,
            location:            location,
            details:             details_payload,
            participants:        resolved_participants,
            time_minutes:        time_minutes,
            references_event_id: references_event_id
          )
        end

        if (pa_args = args["creates_pending_appearance"]).is_a?(Hash) && result["event_id"]
          pa_outcome = create_pending_appearance(pa_args, result["event_id"], location, context)
          result["pending_appearance"] = pa_outcome
        end

        result
      end

      private

      def create_pending_appearance(pa_args, event_id, event_location, context)
        target_id = pa_args["target_character_id"]
        intent    = pa_args["intent_text"]
        return { "error" => "target_character_id required" } unless target_id.is_a?(Integer)
        return { "error" => "intent_text required (non-empty string)" } unless intent.is_a?(String) && !intent.strip.empty?

        target = ::Character.find_by(id: target_id)
        return { "error" => "no character with id=#{target_id}" } unless target

        scope = pa_args["scope"] || "city"
        unless PENDING_APPEARANCE_SCOPES.include?(scope)
          return { "error" => "scope must be one of: #{PENDING_APPEARANCE_SCOPES.join(', ')}" }
        end

        anchor = if pa_args["anchor_location_id"]
          loc = ::Location.find_by(id: pa_args["anchor_location_id"])
          return { "error" => "anchor_location_id #{pa_args['anchor_location_id']} not found" } unless loc
          loc
        else
          event_location
        end

        offset = pa_args["earliest_at_offset_minutes"]
        offset = 60 unless offset.is_a?(Integer) && offset >= 0
        earliest_at = (context.game_time || 0) + offset

        actor_char_id = pa_args["actor_character_id"]
        origin_char   = pa_args["origin_character_id"]
        origin_fac    = pa_args["origin_faction_id"]

        if pa_args["actor_name"]
          return { "error" => "pending_appearance.actor_name is no longer supported — class-2 strings retired post-Phase-2. Pass actor_character_id (call propose_character first if needed)." }
        end

        if actor_char_id && !::Character.exists?(id: actor_char_id)
          return { "error" => "actor_character_id #{actor_char_id} not found" }
        end
        if origin_char && !::Character.exists?(id: origin_char)
          return { "error" => "origin_character_id #{origin_char} not found" }
        end
        if origin_fac && !::Faction.exists?(id: origin_fac)
          return { "error" => "origin_faction_id #{origin_fac} not found" }
        end

        pa = ::PendingAppearance.new(
          triggered_by_event_id: event_id,
          target_character_id:   target.id,
          origin_character_id:   origin_char,
          origin_faction_id:     origin_fac,
          actor_character_id:    actor_char_id,
          intent_text:           intent.strip,
          anchor_location_id:    (scope == "anywhere" ? nil : anchor&.id),
          scope:                 scope,
          earliest_at:           earliest_at
        )

        if pa.save
          {
            "id"          => pa.id,
            "target_id"   => pa.target_character_id,
            "scope"       => pa.scope,
            "earliest_at" => pa.earliest_at
          }
        else
          { "error" => pa.errors.full_messages.join("; ") }
        end
      end

      def forward_append(context:, scope:, location:, details:, participants:, time_minutes:, references_event_id: nil)
        ::Harness::Clock.advance(context, minutes: time_minutes, reason: "propose_event(forward)")
        event = ::Harness::Event::ForwardAppender.append(
          game_time:           context.game_time,
          scope:               scope,
          location:            location,
          details:             details,
          participants:        participants,
          references_event_id: references_event_id
        )
        success_result(event, scope, location, context.game_time, participants, mode: "forward")
      end

      def backward_append(context:, game_time:, scope:, location:, details:, participants:, references_event_id: nil)
        result = ::Harness::Event::BackwardAppender.append(
          events: [ {
            game_time:           game_time,
            scope:               scope,
            location:            location,
            details:             details,
            participants:        participants,
            references_event_id: references_event_id
          } ],
          llm_client: context.llm_grunt
        )
        success_result(result.events.first, scope, location, game_time, participants, mode: "backward",
                       extra: { "after_event_count" => result.after_event_count, "validator_called" => result.validator_called })
      rescue ::Harness::Event::BackwardAppender::FloorViolation => e
        { "error" => e.message, "kind" => "floor_violation" }
      rescue ::Harness::Event::BackwardAppender::Rejected => e
        { "error" => e.message, "kind" => "contradiction", "reasons" => e.reasons }
      end

      def success_result(event, scope, location, game_time, participants, mode:, extra: {})
        {
          "event_id"     => event.id,
          "mode"         => mode,
          "scope"        => scope,
          "location_id"  => location&.id,
          "game_time"    => game_time,
          "participants" => participants.map { |p|
            { "character_id" => p[:character].id, "role" => p[:role] }
          }
        }.merge(extra)
      end
    end
  end
end
