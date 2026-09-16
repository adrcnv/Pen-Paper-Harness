module Harness
  module Scene
    # When is a venue open? The single source of truth for staffed hours:
    # a keeper's :working state derives from their post venue's hours
    # (Routine), the draw won't send patrons into a shut room (LocalDraw),
    # a closed venue's own residents are asleep upstairs — absent from the
    # scene (Assembler) — and a barred venue refuses entry (Transition).
    # Classification is mechanical: name keywords → kind → open phases.
    # Unclassified venues have no opinion (always open) so nothing
    # mysteriously empties.
    #
    # Taverns are the always-open refuge: staffed round the clock (user
    # ruling 2026-09-15: a keeper's off-hours read as a vendor vacuum and a
    # bug, not as a life — the demo opens at 10:41 into empty taprooms) —
    # and they NEVER bar the door.
    module VenueHours
      HOURS = {
        "tavern" => [ :morning, :day, :evening, :night ].freeze,
        "inn"    => [ :morning, :day, :evening ].freeze,
        "shrine" => [ :morning, :evening ].freeze,
        "trade"  => [ :morning, :day ].freeze
      }.freeze

      KIND_WORDS = {
        "tavern" => [ "tavern", "alehouse", "taproom", "common room", "public house", "pub", "brewhouse" ].freeze,
        "inn"    => [ "inn", "lodge", "hostel" ].freeze,
        "shrine" => [ "shrine", "chapel", "temple", "sanctum" ].freeze,
        "trade"  => [ "mill", "smith", "smithy", "forge", "market", "bakery", "tannery",
                      "shed", "loft", "yard", "dock", "docks", "landing", "wharf", "pier",
                      "warehouse", "counting house", "office" ].freeze
      }.freeze

      module_function

      def kind(location)
        return nil unless location
        props = location.properties.is_a?(Hash) ? location.properties : {}
        # A manifest venue says what it is; a minted one may not carry the
        # word in its name ("the Sunken Cask", described as a tavern — its
        # keeper drifted to the town and the bar stood empty, items run 7).
        # Name first, then the manifest key, then the description.
        [ location.name, props["manifest_key"], props["trade"], location.description.to_s.split(/(?<=[.!?])\s/).first ].each do |text|
          t = text.to_s.downcase
          next if t.empty?
          KIND_WORDS.each do |k, words|
            return k if words.any? { |w| t.match?(/\b#{::Regexp.escape(w)}\b/) }
          end
        end
        nil
      end

      def open?(location, phase)
        k = kind(location)
        return true unless k
        HOURS[k].include?(phase)
      end

      def closed?(location, phase)
        !open?(location, phase)
      end

      # Door policy: a classified venue outside its staffed hours refuses
      # entry — except taverns (presence-only closure, see above).
      # Unclassified places never bar.
      def barred?(location, phase)
        k = kind(location)
        return false if k.nil? || k == "tavern"
        !HOURS[k].include?(phase)
      end

      # Presence rule for a location's OWN residents: classified venues
      # follow their HOURS (the tavern keeper is always at the bar); everywhere
      # else follows the day/night rhythm (asleep at night).
      def residents_present?(location, phase)
        k = kind(location)
        return HOURS[k].include?(phase) if k
        phase != :night
      end
    end
  end
end
