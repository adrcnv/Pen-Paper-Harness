module Harness
  module Tools
    # Inter-city travel between top-level coordinated Locations. The cursor
    # walks from the player's anchor toward the destination in steps;
    # per-step encounter dice may stop the journey early at a freshly-spawned
    # wilderness_leaf, and known-location proximity may snap the cursor to
    # an existing top-level Location. Otherwise the cursor advances all the
    # way to the destination and arrival is announced.
    #
    # Resumption: a Journey row persists between calls. Calling travel with
    # the same destination_id resumes from the cursor; with a different
    # destination_id throws away the existing journey and starts fresh from
    # the player's current top-level anchor.
    #
    # Within-scene movement (parent/child/sibling sublocations) is the
    # `transition` tool's job, not travel's. Travel only operates between
    # top-level Locations with coordinates.
    class Travel < Base
      MIN_PER_DISTANCE   = 2.0   # baseline minutes per unit of map distance
      MIN_COST_MIN       = 1
      SEGMENT_DISTANCE   = 2.0   # cursor advance per step (smaller = more dice rolls per trip)
      SNAP_RADIUS        = 5.0   # if any known top-level is within this distance of the segment, snap to it

      def self.tool_name
        "travel"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Travel between top-level coordinated Locations (city → city, city → wilderness, etc). Resolve the destination via query_location_by_name first; if the player is heading somewhere off-map, call propose_location (wilderness_leaf) to create a row, then travel to that id. The system advances the cursor, may snap to a known location passed along the way, and stops at the destination on arrival. Re-calling travel with the same destination_id resumes a paused journey.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "destination_id" => { "type" => "integer", "description" => "id of a top-level Location with coordinates" }
            },
            "required" => [ "destination_id" ]
          }
        }
      end

      def initialize(rng: Random.new, logger: Rails.logger)
        @rng    = rng
        @logger = logger
      end

      def call(args, context)
        id = args["destination_id"]
        return { "error" => "destination_id required" } if id.nil?

        dest = ::Location.find_by(id: id)
        return { "error" => "no location with id=#{id}" } unless dest
        return { "error" => "destination must be a top-level Location with coordinates (got parent_id=#{dest.parent_id.inspect}, x=#{dest.x.inspect}, y=#{dest.y.inspect})" } unless top_level_with_coords?(dest)

        anchor = top_level_anchor(context.player_location)
        return { "error" => "player is not at a top-level coordinated location — cannot start a journey from #{context.player_location.name}" } unless anchor

        if anchor.id == dest.id
          return { "error" => "already at #{dest.name}" }
        end

        journey = ::Journey.start_or_replace(
          destination:          dest,
          origin_x:             anchor.x,
          origin_y:             anchor.y,
          started_at_game_time: context.game_time || 0
        )

        # Cursor walk loop. Per step: check arrival, check snap, check
        # encounter dice, advance. The anchor + destination are excluded from
        # snap candidates so we don't snap back to start or pre-empt arrival.
        walk(journey, dest, context, exclude_snap_ids: [ anchor.id, dest.id ])
      end

      private

      def walk(journey, dest, context, exclude_snap_ids:)
        total_minutes = 0

        loop do
          dist = Math.hypot(dest.x - journey.cursor_x, dest.y - journey.cursor_y)

          # Arrival when within one snap-radius of destination.
          if dist <= SNAP_RADIUS
            total_minutes += step_minutes(dist, journey.cursor_x, journey.cursor_y, dest.x, dest.y)
            advance_cursor(journey, dest.x, dest.y, total_minutes)
            apply_arrival(context, dest, total_minutes, journey)
            ::Journey.delete_all  # arrived → no active journey
            return {
              "outcome"     => "arrived",
              "destination" => { "id" => dest.id, "name" => dest.name },
              "minutes"     => total_minutes,
              "game_time"   => context.game_time
            }
          end

          # Step: advance cursor toward destination.
          step_dist = [ SEGMENT_DISTANCE, dist ].min
          ratio     = step_dist / dist
          new_x     = journey.cursor_x + (dest.x - journey.cursor_x) * ratio
          new_y     = journey.cursor_y + (dest.y - journey.cursor_y) * ratio
          step_min  = step_minutes(step_dist, journey.cursor_x, journey.cursor_y, new_x, new_y)

          # Snap check: any known top-level Location whose point-line distance
          # to this segment is within SNAP_RADIUS? Excludes both the journey
          # origin (else we snap back to start on step 1) and the destination
          # (arrival is its own outcome).
          snap = check_snap(journey.cursor_x, journey.cursor_y, new_x, new_y, dest.x, dest.y, exclude_ids: exclude_snap_ids)
          if snap
            total_minutes += step_min
            advance_cursor(journey, snap.x, snap.y, total_minutes)
            apply_snap(context, snap, total_minutes, journey)
            return {
              "outcome"      => "snapped",
              "snapped_to"   => { "id" => snap.id, "name" => snap.name },
              "minutes"      => total_minutes,
              "destination"  => { "id" => dest.id, "name" => dest.name },
              "remaining_distance" => journey.remaining_distance.round(2),
              "game_time"    => context.game_time
            }
          end

          # Encounter check: dice + cooldown + bucket pick + place-gen.
          # Skipped silently when no llm_grunt (test/dry-run setups).
          if context.llm_grunt && encounter_fires?(journey, context, total_minutes + step_min)
            bucket = ::Harness::Travel::EncounterPolicy.pick_bucket(rng: @rng)
            @logger.info { "[Tools::Travel] encounter fires bucket=#{bucket} at (#{new_x.round(2)}, #{new_y.round(2)})" }
            spawned = spawn_encounter(bucket, new_x, new_y, context)
            if spawned
              total_minutes += step_min
              advance_cursor(journey, new_x, new_y, total_minutes)
              new_cooldown = (context.game_time || 0) + total_minutes + ::Harness::Travel::EncounterPolicy::COOLDOWN_MINUTES
              journey.update!(cooldown_until_game_time: new_cooldown)
              apply_encounter(context, spawned[:location], total_minutes)
              return {
                "outcome"            => "encounter",
                "encounter_type"     => bucket,
                "place"              => { "id" => spawned[:location].id, "name" => spawned[:location].name, "description" => spawned[:location].description },
                "minutes"            => total_minutes,
                "destination"        => { "id" => dest.id, "name" => dest.name },
                "remaining_distance" => journey.remaining_distance.round(2),
                "game_time"          => context.game_time
              }
            end
            # spawn_encounter returned nil (LLM failure or name-collision exhaustion)
            # — fall through and just advance the cursor.
          end

          total_minutes += step_min
          journey.cursor_x = new_x
          journey.cursor_y = new_y
        end
      end

      def encounter_fires?(journey, context, projected_extra_minutes)
        projected_game_time = (context.game_time || 0) + projected_extra_minutes
        fires = ::Harness::Travel::EncounterPolicy.fires?(
          journey:           journey,
          current_game_time: projected_game_time,
          rng:               @rng
        )
        @logger.debug { "[Tools::Travel] encounter dice journey=#{journey.id} t=#{projected_game_time} cooldown_until=#{journey.cooldown_until_game_time} fires=#{fires}" }
        fires
      end

      def spawn_encounter(bucket, x, y, context)
        anchor = ::Harness::Travel::EncounterSpawner.nearest_top_level(x, y)
        biome  = anchor&.biome || ::Harness::Worldgen::Biome::LOWLAND

        place = ::Harness::Travel::EncounterPlace
          .new(llm_client: context.llm_grunt, logger: @logger)
          .generate(bucket: bucket, biome: biome, anchor_name: anchor&.name)

        ::Harness::Travel::EncounterSpawner.spawn(
          name:           place.name,
          description:    place.description,
          x:              x,
          y:              y,
          encounter_type: bucket,
          context:        context
        )
      rescue StandardError => e
        @logger.warn { "[Tools::Travel] encounter spawn failed: #{e.class}: #{e.message}" }
        nil
      end

      def apply_encounter(context, leaf, minutes)
        from = context.player_location
        followers = followers_at(from)
        ::Harness::Clock.advance(context, minutes: minutes, reason: "travel(encounter at #{leaf.name})")
        context.player_location = leaf
        context.scene_dirty = true
        ::Player.first&.update!(location_id: leaf.id)
        relocate_followers!(followers, leaf)
      end

      def step_minutes(distance, ax, ay, bx, by)
        avg_mult = (biome_multiplier_at(ax, ay) + biome_multiplier_at(bx, by)) / 2.0
        cost = (distance * MIN_PER_DISTANCE * avg_mult).round
        [ cost, MIN_COST_MIN ].max
      end

      # Approximation: the biome of the nearest known top-level. Without a
      # persisted noise field we can't sample the underlying biome directly.
      def biome_multiplier_at(x, y)
        nearest = nearest_top_level(x, y)
        ::Harness::Worldgen::Biome.cost_multiplier(nearest&.biome)
      end

      def nearest_top_level(x, y)
        ::Location.where(parent_id: nil).where.not(x: nil, y: nil).order(:id).to_a.min_by { |l|
          Math.hypot(l.x - x, l.y - y)
        }
      end

      # Closest known top-level Location whose point-line distance to the
      # segment (ax,ay) → (bx,by) is within SNAP_RADIUS — AND which is forward
      # progress (strictly closer to the destination than the segment start).
      # The progress filter is load-bearing: a neighbor sitting beside or
      # behind the start (e.g. the city the player just left, 2 units off the
      # route) is within SNAP_RADIUS of the first tiny step and would otherwise
      # snap the player BACKWARD — the "teleported back to the starting city"
      # bug. Origin and destination are excluded by id; everything else must
      # earn the snap by being closer to the goal.
      def check_snap(ax, ay, bx, by, dest_x, dest_y, exclude_ids:)
        start_to_dest = Math.hypot(dest_x - ax, dest_y - ay)
        candidates = ::Location.where(parent_id: nil).where.not(x: nil, y: nil).where.not(id: exclude_ids).to_a
        candidates
          .select { |l| Math.hypot(dest_x - l.x, dest_y - l.y) < start_to_dest } # forward progress only
          .map { |l| [ l, point_segment_distance(l.x, l.y, ax, ay, bx, by) ] }
          .select { |_, d| d <= SNAP_RADIUS }
          .min_by { |_, d| d }
          &.first
      end

      def point_segment_distance(px, py, ax, ay, bx, by)
        dx, dy = bx - ax, by - ay
        return Math.hypot(px - ax, py - ay) if dx.zero? && dy.zero?
        t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
        t = [ [ t, 0.0 ].max, 1.0 ].min
        Math.hypot(px - (ax + t * dx), py - (ay + t * dy))
      end

      def advance_cursor(journey, x, y, elapsed)
        journey.cursor_x = x
        journey.cursor_y = y
        journey.elapsed_minutes = (journey.elapsed_minutes || 0) + elapsed
        journey.save!
      end

      def apply_arrival(context, dest, minutes, journey)
        from = context.player_location
        followers = followers_at(from)
        ::Harness::Clock.advance(context, minutes: minutes, reason: "travel(arrived #{dest.name})")
        context.player_location = dest
        context.scene_dirty = true
        ::Player.first&.update!(location_id: dest.id)
        relocate_followers!(followers, dest)
      end

      def apply_snap(context, snap, minutes, journey)
        from = context.player_location
        followers = followers_at(from)
        ::Harness::Clock.advance(context, minutes: minutes, reason: "travel(snapped to #{snap.name})")
        context.player_location = snap
        context.scene_dirty = true
        ::Player.first&.update!(location_id: snap.id)
        relocate_followers!(followers, snap)
      end

      # NPCs at `loc` whose properties carry `following_player: true` —
      # see Tools::Transition for the rationale (Ruby-side filter to dodge
      # SQLite/JSON1 boolean coercion). Relocated together with the player
      # at every travel termination point.
      def followers_at(loc)
        ::Npc.where(location_id: loc.id).select { |c|
          c.properties.is_a?(Hash) && c.properties["following_player"] == true
        }
      end

      def relocate_followers!(followers, dest)
        followers.each { |npc| npc.update!(location_id: dest.id) }
      end

      def top_level_with_coords?(loc)
        loc.parent_id.nil? && loc.x.present? && loc.y.present?
      end

      def top_level_anchor(loc)
        current = loc
        while current
          return current if top_level_with_coords?(current)
          current = current.parent
        end
        nil
      end
    end
  end
end
