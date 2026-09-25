module Harness
  module Scene
    # Shared helpers for the draw mechanisms — TravelerPull (cross-city) and
    # LocalDraw (intra-city). Both pick an existing free NPC by SCHEDULE and
    # pin them into the current scene (Whereabouts honors the pin); both rely
    # on the SAME notion of "eligible to be drawn" and the SAME walk of a
    # location's full city ancestry. Kept in one place so the eligibility rule
    # can't drift between the two draws.
    module Residents
      module_function

      # An NPC row that may be relocated into a scene: alive, not following the
      # player, not a dormant historical, and homed in an actual settlement
      # (a lair-homed bandit is never drawn in as a peaceful passer-by).
      def eligible?(c)
        !dormant?(c) && !follower?(c) && !deceased?(c) && c.home_location&.settlement?
      end

      def dormant?(c)  = c.properties.is_a?(Hash) && c.properties["dormant"] == true
      def follower?(c) = c.properties.is_a?(Hash) && c.properties["following_player"] == true
      # Dead = had a body and lost it. A row with no max HP never had stats:
      # a keeper named at layout and not yet met (unmaterialized?), whom
      # Scene::Manager materialises on first meeting.
      def deceased?(c)       = c.max_hp.to_i > 0 && c.current_hp.to_i <= 0
      def unmaterialized?(c) = c.max_hp.to_i <= 0

      # The whole city of a location: the top-level root + every descendant.
      # A resident of any sublocation of THIS city counts as local.
      def ancestry_ids(loc)
        root = loc
        root = root.parent while root.parent
        [ root.id ] + descendant_ids(root)
      end

      def descendant_ids(loc)
        kids = ::Location.where(parent_id: loc.id).to_a
        kids.map(&:id) + kids.flat_map { |k| descendant_ids(k) }
      end
    end
  end
end
