module Harness
  module Scene
    # Active ⇄ JSON-safe hash, for the session_states row (turn-boundary
    # flush + replay-rig restore). Only DATA serializes: the `snapshot`
    # member (AR rows) is rebuilt from the DB via Assembler.for on load —
    # a pure read, so restore stays inert (no draws, no LLM, no genesis).
    #
    # Combat state is NOT serialized (v1): rewinding into a live fight is
    # unsupported; dump logs a warn and drops it. Everything else survives
    # the round-trip, including the integer character-id keys JSON stringifies.
    module Serializer
      module_function

      def dump(active, logger: Rails.logger)
        return nil unless active
        if active.in_combat?
          logger.warn { "[Scene::Serializer] combat state not serialized — a restore lands out of combat" }
        end
        {
          "location_id"          => active.location&.id,
          "narrations"           => active.narrations || [],
          "internal_state"       => active.internal_state || {},
          "agendas"              => active.agendas || {},
          "extras"               => active.extras || [],
          "entered_at_game_time" => active.entered_at_game_time,
          "initiative_cooldown"  => active.initiative_cooldown,
          "last_initiator"       => active.last_initiator,
          "spoken_ids"           => active.spoken_ids || [],
          "last_lines"           => active.last_lines || {},
          "contest_ledger"       => active.contest_ledger || {},
          "dispositions"         => active.dispositions || {}
        }
      end

      def load(data)
        return nil unless data.is_a?(Hash)
        location = ::Location.find_by(id: data["location_id"])
        return nil unless location

        Active.new(
          location:             location,
          snapshot:             Assembler.for(location: location),
          narrations:           Array(data["narrations"]),
          internal_state:       int_keyed(data["internal_state"]),
          agendas:              int_keyed(data["agendas"]),
          extras:               Array(data["extras"]),
          entered_at_game_time: data["entered_at_game_time"],
          initiative_cooldown:  data["initiative_cooldown"],
          last_initiator:       data["last_initiator"],
          spoken_ids:           Array(data["spoken_ids"]).map(&:to_i),
          last_lines:           int_keyed(data["last_lines"]),
          contest_ledger:       data["contest_ledger"] || {},
          dispositions:         int_keyed(data["dispositions"])
        )
      end

      # JSON round-trips hash keys to strings; scene consumers index by
      # integer character id (state_for(c.id) etc.).
      def int_keyed(hash)
        return {} unless hash.is_a?(Hash)
        hash.transform_keys { |k| k.to_s =~ /\A\d+\z/ ? k.to_i : k }
      end
    end
  end
end
