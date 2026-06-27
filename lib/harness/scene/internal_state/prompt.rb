require "json"

module Harness
  module Scene
    class InternalState
      module Prompt
        PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/scene_internal_state.txt")

        # Number of recent events per character to surface as context.
        # Keep tight — internal state is flavor, not a recap.
        RECENT_EVENT_LIMIT = 3

        # The only properties keys this prompt actually uses (mood hooks +
        # agenda grounding + follower exclusion). The full properties blob
        # carries a dozen unused keys (gender, dormant, home_location_id,
        # pending_*, manifest_key, substance_seeded…) — dumping it whole on
        # every present character, every scene entry, is pure token waste at
        # local-model speeds. Trim to what the prompt reads.
        MOOD_PROPERTY_KEYS = %w[personality physical appearance mood lens following_player].freeze

        def self.render(location:, characters:)
          {
            system: preamble,
            user:   "INPUT:\n#{JSON.pretty_generate(input_hash(location, characters))}"
          }
        end

        def self.input_hash(location, characters)
          {
            "location"   => location_hash(location),
            "characters" => characters.map { |c| character_hash(c) }
          }
        end

        def self.location_hash(loc)
          {
            "name"        => loc.name,
            "description" => loc.description
          }.compact
        end

        def self.character_hash(c)
          {
            "name"          => c.name,
            "subrole"       => c.subrole,
            "properties"    => mood_properties(c),
            "recent_events" => recent_events(c)
          }
        end

        # Only the keys the prompt reads (see MOOD_PROPERTY_KEYS) — not the
        # whole properties blob.
        def self.mood_properties(c)
          props = c.properties.is_a?(Hash) ? c.properties : {}
          props.slice(*MOOD_PROPERTY_KEYS)
        end

        def self.recent_events(c)
          ::EventParticipant
            .joins(:event)
            .where(character_id: c.id)
            .order("events.game_time DESC, events.id DESC")
            .limit(RECENT_EVENT_LIMIT)
            .includes(:event)
            .map { |ep|
              ev = ep.event
              {
                "role"      => ep.role,
                "scope"     => ev.scope,
                "details"   => ev.details
              }
            }
        end

        def self.preamble
          @preamble ||= Harness::Prompts::Preamble.load(PREAMBLE_PATH)
        end
      end
    end
  end
end
