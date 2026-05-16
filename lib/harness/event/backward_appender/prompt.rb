require "json"

module Harness
  module Event
    class BackwardAppender
      module Prompt
        PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/backward_append_validator.txt")

        def self.render(events:, after_events:)
          {
            system: preamble,
            user:   "INPUT:\n#{JSON.pretty_generate(input_hash(events, after_events))}"
          }
        end

        def self.input_hash(events, after_events)
          {
            "proposed_cluster" => events.each_with_index.map { |e, i| event_hash(e, index: i) },
            "after_events"     => after_events.map { |ev| existing_event_hash(ev) }
          }
        end

        def self.event_hash(e, index:)
          {
            "index"        => index,
            "game_time"    => e[:game_time],
            "scope"        => e[:scope],
            "location"     => location_label(e[:location]),
            "details"      => e[:details],
            "participants" => Array(e[:participants]).map { |p|
              { "name" => p[:character]&.name, "role" => p[:role] }
            }
          }
        end

        def self.existing_event_hash(ev)
          {
            "id"           => ev.id,
            "game_time"    => ev.game_time,
            "scope"        => ev.scope,
            "location"     => ev.location&.name || ev.details["location_name"],
            "details"      => ev.details,
            "participants" => ev.event_participants.map { |ep|
              { "name" => ep.character&.name, "role" => ep.role }
            }
          }
        end

        def self.location_label(loc)
          case loc
          when ::Location then loc.name
          when String     then loc
          else                 nil
          end
        end

        def self.preamble
          @preamble ||= Harness::Prompts::Preamble.load(PREAMBLE_PATH)
        end
      end
    end
  end
end
