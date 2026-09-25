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
      def self.ensure!(location, llm:, logger: Rails.logger, rng: Random.new)
        return nil unless location&.parent_id
        trade = trade_of(location)
        return nil if trade.empty?
        return nil if staffed?(location, trade)

        # Adoption before spawning: a trade-matching resident anchored at the
        # settlement root IS this venue's keeper waiting to be claimed —
        # re-anchoring them here beats minting a second smith for the town.
        if location.parent_id && (adopted = adoptable_keeper(location, trade))
          adopted.update!(home_location_id: location.id, location_id: location.id)
          logger.info { "[Scene::StaffSeeder] adopted #{adopted.name} (#{trade}) as keeper of #{location.name}" }
          return adopted
        end

        npc = ::Harness::Character::Hatchery.spawn(
          llm_grunt:        llm,
          name:             ::Harness::Naming.unique_for(location: location, rng: rng),
          subrole:          trade,
          location_id:      location.id,
          home_location_id: location.id,
          prose_context:    "Keeper of #{location.name} (#{location.description.to_s.slice(0, 200)})",
          rng:              rng
        )
        logger.info { "[Scene::StaffSeeder] #{npc.name} (#{trade}) keeps #{location.name}" }
        npc
      rescue StandardError => e
        logger.warn { "[Scene::StaffSeeder] failed for #{location&.name}: #{e.class}: #{e.message}" }
        nil
      end

      # Name the keeper of every trade room in the settlement that has none:
      # a row with a name, a trade and a home, no stats yet — the town knows
      # its smith's name before the player meets him (roster-4: a voice
      # guessed "Doric" for a smith whose room stood empty, because the fact
      # had no name to give). Adoption first, as ensure! does. The body comes
      # at first meeting (Scene::Manager#materialize_present!). No LLM.
      def self.name_all!(root, rng: Random.new, logger: Rails.logger)
        return [] unless root&.settlement? && root.parent_id.nil?
        ::Location.where(parent_id: root.id).order(:id).filter_map do |room|
          trade = trade_of(room)
          next if trade.empty? || staffed?(room, trade)
          if (adopted = adoptable_keeper(room, trade))
            adopted.update!(home_location_id: room.id, location_id: room.id)
            logger.info { "[Scene::StaffSeeder] adopted #{adopted.name} (#{trade}) as keeper of #{room.name}" }
            next adopted
          end
          npc = ::Npc.create!(name: ::Harness::Naming.unique_for(location: room, rng: rng), subrole: trade,
                              location_id: room.id, home_location_id: room.id)
          logger.info { "[Scene::StaffSeeder] #{npc.name} (#{trade}) named keeper of #{room.name} — met later" }
          npc
        end
      end

      def self.trade_of(location) = location.properties.is_a?(Hash) ? location.properties["trade"].to_s : ""

      # A living keeper, met or not yet (a named row has no HP either way).
      def self.staffed?(location, trade)
        ::Npc.where(home_location_id: location.id, subrole: trade).any? { |c| !Residents.deceased?(c) }
      end

      def self.adoptable_keeper(location, trade)
        root = location
        root = root.parent while root.parent
        ::Npc.where(home_location_id: root.id, subrole: trade).to_a.find { |c|
          (c.current_hp.to_i > 0 || c.max_hp.to_i <= 0) &&
            !(c.properties.is_a?(Hash) && (c.properties["dormant"] == true || c.properties["following_player"] == true))
        }
      end
    end
  end
end
