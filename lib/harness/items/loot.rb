module Harness
  module Items
    # Death-loot helper. When a character drops to 0 HP, their items
    # detach from them and anchor to the location they died at —
    # available for any character at that location to pick up next turn
    # via Tools::Pickup.
    #
    # Coins stay on the deceased character row (they're a column, not an
    # Item). The reasoning loop loots coins via Tools::TransferCoins
    # against the corpse — see the ECONOMY section of reasoning.txt.
    module Loot
      class << self
        # Detach all items from `deceased` and anchor them to the
        # location they died at. Returns the touched items (now anchored).
        # No-op if the deceased had no items, or no location to drop to.
        def drop_to_floor(deceased)
          return [] unless deceased&.location_id
          items = ::Item.where(character_id: deceased.id).to_a
          return [] if items.empty?
          ::ActiveRecord::Base.transaction do
            items.each { |it| it.update!(character_id: nil, location_id: deceased.location_id) }
          end
          items
        end
      end
    end
  end
end
