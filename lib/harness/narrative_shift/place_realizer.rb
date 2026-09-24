module Harness
  module NarrativeShift
    # The claims pass's door for a place an NPC named. The routing is
    # Settlement::PlaceWriter's (one door for every spoken or asked-for
    # place): link an existing room by name or by the bind judge, mint a
    # scenery kind once per settlement, refuse the rest. A spoken name that
    # binds to nothing stays what it is — a phrase in a fact — and the
    # settlement grows no room for it.
    module PlaceRealizer
      module_function

      # place   : { "name", "about"? }
      # context : Turn::Context (player_location, llm_grunt)
      # → { location_id, name, minted|linked } or nil (refused)
      def run(place:, context:, logger: Rails.logger)
        return nil unless place.is_a?(Hash)
        res = ::Harness::Settlement::PlaceWriter.resolve(
          name: place["name"], about: place["about"], context: context, source: :claim, logger: logger
        )
        return nil if res.refused?
        { "location_id" => res.location.id, "name" => res.location.name, (res.minted? ? "minted" : "linked") => true }
      end
    end
  end
end
