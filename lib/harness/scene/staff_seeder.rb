module Harness
  module Scene
    # The staffing invariant: a manifest venue (its stub carries
    # properties.trade — the proprietor archetype) gets its keeper as a
    # MECHANICAL guarantee — spawned once, named from the kingdom's pools,
    # homed at the venue. The LLM never decides staffing: a keeper is either
    # cast mechanically or they aren't (no casting hints, no retagging a
    # spawned drover into a barkeep). Presence then follows VenueHours (the
    # Assembler hides them off-shift); patrons are everyone else — townsfolk
    # drawn in by schedule. A dead keeper doesn't count as staff, so the
    # next entry seeds a successor.
    class StaffSeeder
      def self.ensure!(location, llm:, logger: Rails.logger)
        return nil unless location&.parent_id
        trade = location.properties.is_a?(Hash) ? location.properties["trade"].to_s : ""
        return nil if trade.empty?
        return nil if ::Npc.where(home_location_id: location.id, subrole: trade)
                          .any? { |c| c.max_hp.to_i <= 0 || c.current_hp.to_i > 0 }

        npc = ::Harness::Character::Hatchery.spawn(
          llm_grunt:        llm,
          name:             ::Harness::Naming.unique_for(location: location),
          subrole:          trade,
          location_id:      location.id,
          home_location_id: location.id,
          prose_context:    "Keeper of #{location.name} (#{location.description.to_s.slice(0, 200)})"
        )
        logger.info { "[Scene::StaffSeeder] #{npc.name} (#{trade}) keeps #{location.name}" }
        npc
      rescue StandardError => e
        logger.warn { "[Scene::StaffSeeder] failed for #{location&.name}: #{e.class}: #{e.message}" }
        nil
      end
    end
  end
end
