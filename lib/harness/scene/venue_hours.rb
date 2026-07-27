module Harness
  module Scene
    # When is a venue open? The single source of truth for staffed hours:
    # a keeper's :working state derives from their post venue's hours
    # (Routine), the draw won't send patrons into a shut room (LocalDraw),
    # and a closed venue's own residents are asleep upstairs — absent from
    # the scene (Assembler). Classification is mechanical: name keywords →
    # kind → open phases. Unclassified venues have no opinion (always open)
    # so nothing mysteriously empties. Night closes everything; that rule
    # lives in the consumers (Routine :off, Assembler night-hide), so the
    # phases here only span morning/day/evening.
    module VenueHours
      HOURS = {
        "tavern" => [ :day, :evening ].freeze,
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
    end
  end
end
