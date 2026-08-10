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
    # Taverns are the always-open refuge: staffed day/evening/NIGHT (night
    # arrivals possible and safe), keeper asleep only of a morning — and
    # they NEVER bar the door (their closure is presence-only; a barred
    # tavern would lock out the guest who stepped outside at 09:30).
    module VenueHours
      HOURS = {
        "tavern" => [ :day, :evening, :night ].freeze,
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
        name = location&.name.to_s.downcase
        return nil if name.empty?
        KIND_WORDS.each do |k, words|
          return k if words.any? { |w| name.match?(/\b#{::Regexp.escape(w)}\b/) }
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
      # follow their HOURS (the tavern keeper works nights and sleeps of a
      # morning); everywhere else follows the day/night rhythm (asleep at
      # night).
      def residents_present?(location, phase)
        k = kind(location)
        return HOURS[k].include?(phase) if k
        phase != :night
      end
    end
  end
end
