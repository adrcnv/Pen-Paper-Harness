module Harness
  module Runners
    # The player asks after a place — "is there a tavern?", "find me a
    # smith", "somewhere quiet to talk". The answer is the settlement's:
    # Settlement::PlaceWriter links the room it has (by name or by the bind
    # judge), mints a scenery kind once, or says there is no such place.
    # Nothing is authored here any more. A hamlet asked for a smith got
    # three smithies and a second taproom in thirty turns (2026-09-22): the
    # manifest had laid the town out and the materializer dresses each room
    # on approach, so an author had nothing left to do but overbuild.
    class Worldbuilding < Base
      def run(context:, scene:, input:, step:)
        res = ::Harness::Settlement::PlaceWriter.resolve(
          name: input, about: step&.intent, context: context, source: :ask, logger: @logger
        )
        if res.refused?
          settlement = ::Harness::Settlement::PlaceWriter.root_of(context.player_location)
          @logger.info { "[Runner worldbuilding] no such place for #{input.to_s[0, 60].inspect}" }
          # An answer, not filler: a null line stays blank beside a rendering
          # sibling, and an NPC's unprompted line swallowed "nothing of the
          # kind" twice in places run 1 (2026-09-22). A record renders in
          # causal order like the discovery line.
          record = tool_call("resolve_location", { "asked" => input.to_s },
                             { "status" => "refused", "settlement" => settlement&.name })
          return Outcome.new(tool_calls: [ record ], scene_dirty: false, status: :ok, note: "no such place")
        end

        loc = res.location
        @logger.info { "[Runner worldbuilding] #{res.status} #{loc.name.inspect} (##{loc.id}) for #{input.to_s[0, 60].inspect}" }
        # The record Parts renders as the discovery line and the executor
        # hands to a movement step chained behind this one.
        record = tool_call("resolve_location",
                           { "name" => loc.name, "description" => loc.description.to_s },
                           { "location_id" => loc.id, "name" => loc.name, "status" => res.status.to_s,
                             "type" => (loc.parent_id ? "sublocation" : "settlement") })
        Outcome.new(tool_calls: [ record ], scene_dirty: false, status: :ok)
      end
    end
  end
end
