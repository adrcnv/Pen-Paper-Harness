module Harness
  module NarrativeShift
    # Increment-2 placement — stage a claimed person at their destination when
    # the player arrives.
    #
    # When an NPC names someone at a place that ISN'T a row yet (the relay the
    # player hasn't reached), the Realizer parks that person UNPLACED + dormant
    # with `properties.pending_location_name` set to the named place. Nothing can
    # place them at claim time — the destination doesn't exist. So we place them
    # lazily: when the player finally walks into a location whose name (or an
    # ancestor's name) matches that parked name, we wake them and set them there.
    # "Ask for Harek at the relay" → Harek is actually standing at the relay.
    #
    # Runs from Scene::Manager#enter, before the scene snapshot, so a staged
    # person appears in present_characters THIS entry. Idempotent: placing clears
    # both the dormant flag and pending_location_name, so it never re-fires.
    #
    # Heavily logged on purpose — this is the seam between "an NPC mentioned
    # someone" and "that someone is now in front of the player", and we'll be
    # reading play.log for it a lot.
    module ClaimPlacer
      module_function

      # Place every pending claim whose parked destination matches `location`
      # (or any of its ancestors). Returns the placed Npc rows. Non-fatal.
      def place!(location, logger: Rails.logger)
        return [] unless location

        targets = ancestor_names(location)
        pending = pending_claims
        if pending.empty?
          logger.debug { "[NarrativeShift::ClaimPlacer] no pending claims anywhere on enter #{location.name}" }
          return []
        end

        placed = []
        pending.each do |npc|
          want = parked_name(npc)
          unless targets.include?(want.downcase)
            logger.debug { "[NarrativeShift::ClaimPlacer] #{npc.name} (id=#{npc.id}) pending #{want.inspect} ≠ #{location.name} ancestry #{targets.inspect}" }
            next
          end
          stage!(npc, location)
          logger.info { "[NarrativeShift::ClaimPlacer] PLACED #{npc.name} (id=#{npc.id}) at #{location.name} — was pending #{want.inspect}" }
          placed << npc
        end
        placed
      rescue StandardError => e
        logger.warn { "[NarrativeShift::ClaimPlacer] place failed at #{location&.name}: #{e.class}: #{e.message}" }
        []
      end

      # Wake (clear dormant), anchor here (location + home), and drop the parked
      # name so a later entry can't double-place.
      def stage!(npc, location)
        props = npc.properties.is_a?(Hash) ? npc.properties.dup : {}
        props.delete("pending_location_name")
        props.delete("dormant")
        npc.update!(location_id: location.id, home_location_id: location.id, properties: props)
      end

      def pending_claims
        ::Npc.where("json_extract(properties, '$.pending_location_name') IS NOT NULL").to_a
      end

      def parked_name(npc)
        props = npc.properties
        (props.is_a?(Hash) ? props["pending_location_name"] : nil).to_s.strip
      end

      # The entered location's name plus every ancestor's name, downcased — so
      # arriving at a sublocation of the named city also triggers placement.
      def ancestor_names(location)
        names = []
        loc = location
        while loc
          n = loc.name.to_s.strip.downcase
          names << n unless n.empty?
          loc = loc.parent
        end
        names
      end
    end
  end
end
