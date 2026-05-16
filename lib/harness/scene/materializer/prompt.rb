require "json"

module Harness
  module Scene
    class Materializer
      module Prompt
        PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/scene_materializer.txt")

        def self.render(location:, parent:, already_present:, candidates:, target_count:, slots_to_fill:)
          {
            system: preamble,
            user:   "INPUT:\n#{JSON.pretty_generate(input_hash(location, parent, already_present, candidates, target_count, slots_to_fill))}"
          }
        end

        def self.input_hash(location, parent, already_present, candidates, target_count, slots_to_fill)
          {
            "location"        => location_hash(location),
            "parent"          => parent_hash(parent),
            "already_present" => already_present.map { |c| present_hash(c) },
            "candidates"      => candidates.map { |c| candidate_hash(c) },
            "target_count"    => target_count,
            "slots_to_fill"   => slots_to_fill
          }
        end

        def self.location_hash(loc)
          props = loc.properties.is_a?(Hash) ? loc.properties : {}
          {
            "name"        => loc.name,
            "description" => loc.description,
            "kind"        => props["kind"]
          }.compact
        end

        def self.parent_hash(parent)
          return nil unless parent
          {
            "name"        => parent.name,
            "description" => parent.description
          }.compact
        end

        def self.present_hash(c)
          {
            "name"    => c.name,
            "subrole" => c.subrole
          }
        end

        # Each candidate gets a `dormant` flag so the LLM can prefer
        # already-active local NPCs over waking dormant historicals.
        # Preference order baked into the prompt: active > dormant > spawn.
        def self.candidate_hash(c)
          {
            "character_id" => c[:character_id],
            "name"         => c[:name],
            "subrole"      => c[:subrole],
            "dormant"      => c[:dormant],
            "history"      => c[:history]
          }
        end

        def self.preamble
          @preamble ||= Harness::Prompts::Preamble.load(PREAMBLE_PATH)
        end
      end
    end
  end
end
