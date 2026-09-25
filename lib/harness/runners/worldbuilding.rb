module Harness
  module Runners
    # The player asks after a place — "is there a tavern?", "find me a
    # smith", "somewhere quiet to talk". The answer is the settlement's:
    # Settlement::PlaceWriter links the room it has (by name or by the bind
    # judge), mints a scenery kind once, or says there is no such place.
    # Nothing is authored here
    # any more. A hamlet asked for a smith got three smithies and a second
    # taproom in thirty turns (2026-09-22): the manifest had laid the town
    # out and the materializer dresses each room on approach, so an author
    # had nothing left to do but overbuild. Asked for a PERSON — "go find
    # Aebbe", "where would I find the reeve" — it answers nothing: who is
    # where is for the people of the town to say, and the engine pointing
    # the way is a quest marker (ruling 2026-09-24).
    class Worldbuilding < Base
      def run(context:, scene:, input:, step:)
        res = ::Harness::Settlement::PlaceWriter.resolve(
          name: input, about: step&.intent, context: context, source: :ask, logger: @logger
        )
        settlement = ::Harness::Settlement::PlaceWriter.root_of(context.player_location)
        if res.status == :person
          @logger.info { "[Runner worldbuilding] a person asked for, #{res.key.inspect} — not the engine's to point out" }
          return refusal(input, settlement, "No one has been asked.", "person" => res.key)
        end
        if res.refused?
          @logger.info { "[Runner worldbuilding] no such place for #{input.to_s[0, 60].inspect}" }
          # An answer, not filler: a null line stays blank beside a rendering
          # sibling, and an NPC's unprompted line swallowed "nothing of the
          # kind" twice in places run 1 (2026-09-22). A record renders in
          # causal order like the discovery line.
          return refusal(input, settlement, nil)
        end

        discovery(res.location, res.status, input)
      end

      private

      # The record Parts renders as the discovery line and the executor
      # hands to a movement step chained behind this one.
      def discovery(loc, status, input)
        @logger.info { "[Runner worldbuilding] #{status} #{loc.name.inspect} (##{loc.id}) for #{input.to_s[0, 60].inspect}" }
        record = tool_call("resolve_location",
                           { "name" => loc.name, "description" => loc.description.to_s },
                           { "location_id" => loc.id, "name" => loc.name, "status" => status.to_s,
                             "type" => (loc.parent_id ? "sublocation" : "settlement") })
        Outcome.new(tool_calls: [ record ], scene_dirty: false, status: :ok)
      end


      def refusal(input, settlement, text, extra = {})
        record = tool_call("resolve_location", { "asked" => input.to_s },
                           { "status" => "refused", "settlement" => settlement&.name, "line" => text }.merge(extra).compact)
        Outcome.new(tool_calls: [ record ], scene_dirty: false, status: :ok, note: "no such place")
      end
    end
  end
end
