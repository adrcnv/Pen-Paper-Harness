require "json"

module Harness
  module Scene
    class InternalState
      module Prompt
        PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/scene_internal_state.txt")

        # Number of recent events per character to surface as context.
        # Keep tight — internal state is flavor, not a recap.
        RECENT_EVENT_LIMIT = 3

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
            "properties"    => c.properties.is_a?(Hash) ? c.properties : {},
            "recent_events" => recent_events(c)
          }
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
