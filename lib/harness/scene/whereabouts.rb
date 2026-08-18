require "zlib"

module Harness
  module Scene
    # THE presence authority. Where a living NPC is at time t is DERIVED from
    # their schedule, not stored: `characters.location_id` is a cache this
    # organ maintains at its call points (scene entry / rebuild), never a
    # source of truth. Scene assembly reads the cache only AFTER refresh! has
    # written it; everything that asks about rows outside the active scene
    # keys on `home_location_id` (the anchor) instead.
    #
    # resolve(npc, t) precedence, first match wins:
    #   1. follower        — wherever the player is
    #   2. due meet        — an open `meet` obligation in its due window, at
    #                        the meeting place (the certainty draw)
    #   3. open post       — anchor is a venue and VenueHours says open
    #                        (Routine.post_venue; the keeper is at her bar)
    #   4. live pin        — transient stay written by the draws or a
    #                        displacement (flee, teleport); expires at the
    #                        next day-phase boundary
    #   5. asleep          — settlement folk vanish into abstract housing
    #                        (:off resolves nowhere); wilderness dwellers
    #                        sleep AT their lair (literal housing)
    #   6. anchor root     — the settlement root above the anchor: "somewhere
    #                        in town", which is where the unoccupied stand
    #
    # anchor (home_location_id) taxonomy: settlement root = ordinary citizen
    # (housing is abstract), venue sublocation = their post, wilderness lair =
    # they live there, nil = transient scene prop (kept where cached until
    # settle_transients! culls or adopts them at scene exit).
    #
    # No game_time (tests, headless) = no schedule: clockless mode — the
    # cache is truth for every method.
    #
    # WORKERS GET NO PINS: being at your post is derived (tier 3); a pin for
    # it would be redundant stored state. Pins exist only for presence the
    # schedule cannot derive.
    module Whereabouts
      # How early a meet's counterparty takes up their spot (minutes). The
      # late bound is Obligation::BREACH_GRACE — past that the row breaks
      # (sweep_breaches!) and stops resolving anyone anywhere.
      MEET_LEAD = 120

      module_function

      def resolve(npc, game_time)
        return npc.location_id if game_time.nil?
        return ::Player.first&.location_id if Residents.follower?(npc)

        if (meet_loc = due_meet_location_id(npc, game_time))
          return meet_loc
        end

        post = Routine.post_venue(npc)
        phase = ::Harness::Clock.phase(game_time)
        return post.id if post && VenueHours.open?(post, phase)

        if (pin = live_pin_location_id(npc, game_time))
          return pin
        end

        anchor = npc.home_location
        return nil if anchor.nil?
        # Settlement sleepers vanish into abstract housing; a lair's dwellers
        # sleep at the lair — a night raid still finds the camp occupied.
        return anchor.id unless anchor.settlement?
        return nil if Routine.state(npc, game_time) == :off
        # "Somewhere in town" is not "on this street corner": a resident with
        # no scheduled place is only sometimes out and about; the rest are
        # behind doors we don't model — the abstract housing, made literal.
        # The roll is a stable hash per (person, day, phase) so the street
        # holds still within a phase and re-rolls at every boundary.
        return nil unless at_large?(npc, game_time)
        settlement_root_id(anchor)
      end

      # Chance a free-floating resident is visibly out on the streets in any
      # given day-phase. The tuning knob for how busy roots feel.
      STREET_CHANCE = 0.35

      def at_large?(npc, game_time)
        t = game_time.to_i
        key = "#{npc.id}:#{t / ::Harness::Clock::MINUTES_PER_DAY}:#{::Harness::Clock.phase(t)}"
        (::Zlib.crc32(key) % 1000) / 1000.0 < STREET_CHANCE
      end

      # Living, non-dormant NPCs at this location at time t. Union of every
      # tier's candidates plus rows cached here, each confirmed by resolve
      # (precedence enforced: a root resident with a meet due elsewhere is
      # not on the street). Transients (nil anchor) stay where cached.
      def present_at(location, game_time)
        return cached_at(location) if game_time.nil?
        candidates_for(location, game_time).select { |npc|
          resolved = resolve(npc, game_time)
          resolved == location.id || (resolved.nil? && npc.home_location_id.nil? && npc.location_id == location.id)
        }
      end

      # The cache write — the ONLY place living-NPC location_id is maintained.
      # Pull in everyone who resolves here; push out cached-here rows that
      # resolve elsewhere (the smith swept to his forge as you enter the
      # street). Expired pins are cleared in passing. Returns the present set.
      def refresh!(location, game_time, logger: Rails.logger)
        return cached_at(location) if game_time.nil?

        present = present_at(location, game_time)
        present.each do |npc|
          clear_expired_pin!(npc, game_time)
          npc.update!(location_id: location.id) if npc.location_id != location.id
        end

        present_ids = present.map(&:id)
        cached_at(location).reject { |npc| present_ids.include?(npc.id) }.each do |npc|
          clear_expired_pin!(npc, game_time)
          resolved = resolve(npc, game_time)
          next if resolved == npc.location_id
          npc.update!(location_id: resolved)
          logger.debug { "[Scene::Whereabouts] #{npc.name} is elsewhere (#{resolved.inspect})" }
        end

        logger.debug { "[Scene::Whereabouts] #{present.size} present at #{location.name}" }
        present
      end

      # Transient stay: pins a row to a location until the next day-phase
      # boundary — every standing tier (work blocks, venue hours, sleep) is
      # phase-granular, so the boundary is exactly where re-derivation may
      # answer differently; obligations outrank pins minute-by-minute anyway.
      def pin!(npc, location, game_time, logger: Rails.logger)
        return if game_time.nil?
        props = npc.properties.is_a?(::Hash) ? npc.properties : {}
        until_t = next_phase_boundary(game_time)
        npc.update!(properties: props.merge("pin" => { "location_id" => location.id, "until" => until_t }))
        logger.debug { "[Scene::Whereabouts] #{npc.name} pinned at #{location.name} until t=#{until_t}" }
      end

      def live_pin_location_id(npc, game_time)
        pin = npc.properties.is_a?(::Hash) ? npc.properties["pin"] : nil
        return nil unless pin.is_a?(::Hash)
        return nil unless pin["until"].to_i > game_time.to_i
        pin["location_id"]
      end

      def pinned?(npc, game_time) = !live_pin_location_id(npc, game_time).nil?

      # Open meets with the player falling due at this location — early by
      # MEET_LEAD, late within the breach grace. Also the barred-door
      # exemption's test (Tools::Transition): the keeper expecting you opens.
      def due_meets_at(location, now, player)
        window = (now.to_i - ::Obligation::BREACH_GRACE)..(now.to_i + MEET_LEAD)
        ::Obligation.open_now.where(kind: "meet", location_id: location.id)
          .involving(player.id).where(due_time: window)
      end

      def due_here?(location, game_time)
        player = ::Player.first
        return false unless location && game_time && player
        due_meets_at(location, game_time, player).exists?
      rescue ::StandardError
        false
      end

      # Scene-exit lifecycle for transient props (nil anchor): engaged ones
      # (in any event) earn an anchor and go there; pure flavor evaporates.
      # Load-bearing, because nothing else ever removes a homeless row.
      # Anchored cast needs NO action here:
      # the resolver owns them, and their stale cache is corrected wherever
      # someone next looks.
      def settle_transients!(cast, location, logger: Rails.logger)
        Array(cast).each do |npc|
          next unless npc.is_a?(::Npc)
          next if npc.home_location_id
          next if Residents.deceased?(npc) || Residents.dormant?(npc) || Residents.follower?(npc)
          if ::EventParticipant.exists?(character_id: npc.id)
            dest = nearest_settlement(location)
            npc.update!(home_location_id: dest&.id, location_id: dest&.id)
            logger.debug { "[Scene::Whereabouts] transient #{npc.name} earned an anchor at #{dest&.name}" }
          else
            logger.debug { "[Scene::Whereabouts] transient #{npc.name} evaporates" }
            npc.destroy!
          end
        end
      end

      # -- internals ---------------------------------------------------------

      def candidates_for(location, game_time)
        ids = {}
        add = ->(rows) { rows.each { |r| ids[r.id] ||= r } }

        add.call(cached_at(location))
        add.call(living_scope.where(home_location_id: location.id).to_a)
        add.call(living_scope.where(id: due_party_ids(location, game_time)).to_a)
        add.call(pinned_here(location))
        if location.parent_id.nil? && location.settlement?
          add.call(living_scope.where(home_location_id: Residents.ancestry_ids(location)).to_a)
        end
        if (player = ::Player.first) && player.location_id == location.id
          add.call(living_scope.prop_eq("following_player", true).to_a)
        end
        ids.values.reject { |c| Residents.dormant?(c) || Residents.deceased?(c) }
      end

      def due_party_ids(location, now)
        player = ::Player.first
        return [] unless player
        due_meets_at(location, now, player)
          .flat_map { |o| [ o.debtor_id, o.creditor_id ] }.uniq - [ player.id ]
      rescue ::StandardError
        []
      end

      def due_meet_location_id(npc, now)
        window = (now.to_i - ::Obligation::BREACH_GRACE)..(now.to_i + MEET_LEAD)
        ::Obligation.open_now.where(kind: "meet").involving(npc.id)
          .where(due_time: window).where.not(location_id: nil)
          .order(:due_time).limit(1).pick(:location_id)
      rescue ::StandardError
        nil
      end

      def pinned_here(location)
        living_scope
          .where("json_extract(properties, '$.pin.location_id') = ?", location.id)
          .to_a
      end

      def cached_at(location)
        living_scope.where(location_id: location.id).to_a
          .reject { |c| Residents.dormant?(c) || Residents.deceased?(c) }
      end

      def living_scope
        ::Npc.all
      end

      def clear_expired_pin!(npc, game_time)
        pin = npc.properties.is_a?(::Hash) ? npc.properties["pin"] : nil
        return unless pin.is_a?(::Hash)
        return if pin["until"].to_i > game_time.to_i
        npc.update!(properties: npc.properties.except("pin"))
      end

      def settlement_root_id(anchor)
        root = anchor
        root = root.parent while root.parent
        root.id
      end

      def next_phase_boundary(game_time)
        t = game_time.to_i
        minute_of_day = t % ::Harness::Clock::MINUTES_PER_DAY
        day_start = t - minute_of_day
        [ 360, 660, 1020, 1320 ].each do |b|
          return day_start + b if minute_of_day < b
        end
        day_start + ::Harness::Clock::MINUTES_PER_DAY + 360
      end

      def nearest_settlement(location)
        return location if location&.settlement?
        ax = location&.x || 0.0
        ay = location&.y || 0.0
        ::Location.where(parent_id: nil).where.not(x: nil, y: nil).to_a
          .select(&:settlement?)
          .min_by { |l| Math.hypot(l.x - ax, l.y - ay) }
      end
    end
  end
end
