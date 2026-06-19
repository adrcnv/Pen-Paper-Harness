module Harness
  module Scene
    # Runs at scene exit. The old single-location world let NPCs pile up
    # wherever they were spawned — encounter merchants stranded at a roadside
    # crossing for eternity, because nothing ever moved them. With home/current
    # split, exit is where transients leave: anyone standing here who doesn't
    # BELONG here is sent home, culled, or (if the player made them matter)
    # granted a home so they're never stuck again.
    #
    # Rules, per NPC currently at the exited location:
    #   - resident (home == here)        → stays. The town keeps its people.
    #   - displaced dweller (home != here) → location ← home. Goes home.
    #   - homeless (home nil):
    #       - event-bound (in any event) → granted a home (nearest settlement)
    #                                       and sent there; they're "real" now.
    #       - pure flavor (no events)    → culled. They were scenery; props
    #                                       that evaporate with the scene.
    #
    # Never touches: the player, followers (they ride with the player),
    # corpses (the body stays where it fell), or dormant historicals (offstage
    # already, woken by the Materializer, not present).
    class Evictor
      def self.evict!(location, logger: Rails.logger)
        new(location, logger: logger).evict!
      end

      def initialize(location, logger: Rails.logger)
        @location = location
        @logger   = logger
      end

      def evict!
        return [] unless @location
        here = @location.id
        moved = []

        candidates.each do |npc|
          home = npc.home_location_id
          if home == here
            next # resident — belongs here, stays
          elsif home
            npc.update!(location_id: home)                       # displaced → go home
            moved << npc
          elsif ::EventParticipant.exists?(character_id: npc.id)
            dest = nearest_settlement                            # homeless but engaged → earn a home
            npc.update!(home_location_id: dest&.id, location_id: dest&.id)
            moved << npc
          else
            npc.destroy!                                         # homeless flavor → cull
            moved << npc
          end
        end

        @logger.debug { "[Scene::Evictor] #{moved.size} non-resident(s) cleared from #{@location.name}" } if moved.any?
        moved
      end

      private

      # Living, non-follower, non-dormant NPCs standing at the exited location.
      def candidates
        ::Npc.where(location_id: @location.id).reject { |c|
          deceased?(c) || dormant?(c) || follower?(c)
        }
      end

      def deceased?(c) = !c.current_hp.nil? && c.current_hp <= 0
      def dormant?(c)  = c.properties.is_a?(Hash) && c.properties["dormant"] == true
      def follower?(c) = c.properties.is_a?(Hash) && c.properties["following_player"] == true

      # Where a homeless-but-engaged transient is rehomed. The exited location
      # itself if it's a settlement; otherwise the nearest coordinated city.
      def nearest_settlement
        return @location if @location.settlement?
        ax = @location.x || 0.0
        ay = @location.y || 0.0
        ::Location.where(parent_id: nil).where.not(x: nil, y: nil).to_a
          .select(&:settlement?)
          .min_by { |l| Math.hypot(l.x - ax, l.y - ay) }
      end
    end
  end
end
