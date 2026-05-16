module Harness
  module Combat
    # Pure Ruby check after each round to decide whether combat ends.
    # Returns nil to continue, or a symbol identifying the end reason:
    #   :victory      — only one side has alive members left
    #   :player_died  — player at 0 HP
    #   :player_fled  — player no longer at the combat scene's location
    #   :all_fled     — every side has been emptied (escapes / removals)
    #
    # Watchers are NOT counted as combatants — they were never on a side.
    # Dead = max_hp > 0 AND current_hp <= 0 (matches Assembler's partition).
    module Termination
      def self.evaluate(scene)
        state = scene.combat
        return nil unless state

        # Player-state takes priority over side-count: a solo player dying
        # alone means :player_died (game over), not :victory (the enemy
        # side won). Same for player_fled — if the player escaped, that's
        # the outcome we care about even if their side is now empty.
        player = ::Player.first
        if player
          return :player_died if player.max_hp.to_i > 0 && player.current_hp.to_i <= 0
          return :player_fled if player.location_id != scene.location.id
        end

        alive_per_side = group_alive_by_side(state)
        non_empty      = alive_per_side.reject { |_, members| members.empty? }

        return :all_fled if non_empty.empty?
        return :victory  if non_empty.size == 1

        nil
      end

      def self.group_alive_by_side(state)
        grouped = ::Hash.new { |h, k| h[k] = [] }
        # Pre-seed every side that exists so a fully-empty side shows up.
        state.sides.values.uniq.each { |s| grouped[s] }
        state.sides.each do |char_id, side_name|
          char = ::Character.find_by(id: char_id)
          next unless char
          next if char.max_hp.to_i > 0 && char.current_hp.to_i <= 0
          grouped[side_name] << char_id
        end
        grouped
      end
    end
  end
end
