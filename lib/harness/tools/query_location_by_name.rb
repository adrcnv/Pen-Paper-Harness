module Harness
  module Tools
    # Lookup a location by name with three layers of fallback context:
    #   - exact-match row → return its data
    #   - no row → return mention-count from event prose +
    #              the full known-name pool (so the reasoning loop can resolve
    #              "Ice City" → "City of Ice" itself, no fuzzy infrastructure) +
    #              geographic context near the player so a propose_location
    #              call has neighbors to anchor against
    #
    # The reasoning loop should treat `found: false, mentioned_in_events > 0` as
    # "exists in prose, not yet a row — propose_location to promote it"
    # and `found: false, mentioned_in_events == 0` as either
    # "ask one more clarifying question" or "invent it from scratch."
    class QueryLocationByName < Base
      NEARBY_RADIUS_UNITS = 60.0  # ~120 minutes at lowland baseline
      KNOWN_POOL_LIMIT    = 200

      def self.tool_name
        "query_location_by_name"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Find a location by name. Returns {found: true, location_id: N, ...row...} on exact match. On no match, returns {found: false, mentioned_in_events: N, similar_known: [{id, name, parent_id}, ...], geographic_context: {nearby: [{id, name, biome, distance_units, ...}]}}. Every entry carries its `id`; use that id when you call travel/transition. parent_id=null means top-level (travel target); parent_id=N means sublocation under N (transition target). Decide between: (a) re-query with a corrected name, (b) call travel/transition with one of the surfaced ids, (c) propose_location to promote a prose-mentioned place. Use this BEFORE proposing a new location.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "name" => { "type" => "string", "description" => "exact location name to look up" }
            },
            "required" => [ "name" ]
          }
        }
      end

      def call(args, context)
        name = args["name"]
        return { "error" => "name must be a non-empty string" } unless name.is_a?(String) && !name.strip.empty?
        name = name.strip

        if (loc = ::Location.find_by(name: name))
          return found_payload(loc)
        end

        not_found_payload(name, context)
      end

      private

      def found_payload(loc)
        {
          "found"        => true,
          "location_id"  => loc.id,
          "name"         => loc.name,
          "description"  => loc.description,
          "parent_id"    => loc.parent_id,
          "biome"        => loc.biome,
          "x"            => loc.x,
          "y"            => loc.y,
          "faction_id"   => loc.faction_id
        }
      end

      def not_found_payload(name, context)
        mentions = ::Event.where("json_extract(details, '$.location_name') = ?", name).count

        top_level = ::Location.where(parent_id: nil).order(:id).limit(KNOWN_POOL_LIMIT)
                              .pluck(:id, :name)
                              .map { |id, n| { "id" => id, "name" => n, "parent_id" => nil } }
        sub       = nearby_sublocation_entries(context)

        # similar_known is the corrective lookup pool — when the queried name
        # is a typo or a casual reference, the LLM picks the right row by
        # matching the user's intent against this list. Entries carry ids so
        # downstream travel/transition calls can use them; parent_id
        # distinguishes top-level (travel target) from sublocation (transition
        # target). Sublocations are listed first because they're the most
        # likely match for in-city casual references ("the brewery").
        merged = (sub + top_level).uniq { |e| e["id"] }

        {
          "found"               => false,
          "mentioned_in_events" => mentions,
          "similar_known"       => merged,
          "geographic_context"  => geographic_context(context)
        }
      end

      # Sublocations under the player's current city (or its parent if the
      # player is inside one). These are the most-likely match for casual
      # references like "the brewery" or "the smithy" — they should appear
      # in similar_known so the LLM can resolve to an existing row instead
      # of inventing a duplicate.
      def nearby_sublocation_entries(context)
        loc = context.player_location
        return [] unless loc

        parent_id = loc.parent_id || loc.id  # if at the city, its own children; if at a sublocation, its siblings
        ::Location.where(parent_id: parent_id).order(:id).limit(KNOWN_POOL_LIMIT)
                  .pluck(:id, :name, :parent_id)
                  .map { |id, n, p| { "id" => id, "name" => n, "parent_id" => p } }
      end

      def geographic_context(context)
        anchor = top_level_with_coords(context.player_location)
        return { "player_anchor" => nil, "nearby" => [] } unless anchor

        nearby = ::Location.where(parent_id: nil).where.not(id: anchor.id).where.not(x: nil, y: nil).map { |loc|
          dist = Math.hypot(loc.x - anchor.x, loc.y - anchor.y)
          [ loc, dist ]
        }.select { |_, d| d <= NEARBY_RADIUS_UNITS }.sort_by { |_, d| d }

        {
          "player_anchor" => {
            "id"    => anchor.id,
            "name"  => anchor.name,
            "biome" => anchor.biome,
            "x"     => anchor.x,
            "y"     => anchor.y
          },
          "nearby" => nearby.map { |loc, dist|
            {
              "id"               => loc.id,
              "name"             => loc.name,
              "biome"            => loc.biome,
              "distance_units"   => dist.round(1),
              "approx_minutes"   => approx_minutes(dist, anchor.biome, loc.biome),
              "direction"        => compass(anchor.x, anchor.y, loc.x, loc.y)
            }
          }
        }
      end

      def top_level_with_coords(loc)
        current = loc
        while current
          return current if current.x.present? && current.y.present? && current.parent_id.nil?
          current = current.parent
        end
        nil
      end

      # Distance × averaged biome multiplier × MIN_PER_DISTANCE. Same shape
      # as the retired PathBuilder.cost_for — kept inline now that PathBuilder
      # is gone with the rest of the Path model.
      MIN_PER_DISTANCE = 2.0
      MIN_COST_MIN     = 1

      def approx_minutes(distance, biome_a, biome_b)
        avg_mult = (::Harness::Worldgen::Biome.cost_multiplier(biome_a) +
                    ::Harness::Worldgen::Biome.cost_multiplier(biome_b)) / 2.0
        cost = (distance * MIN_PER_DISTANCE * avg_mult).round
        [ cost, MIN_COST_MIN ].max
      end

      # Eight-point compass label from anchor (ax, ay) to target (bx, by).
      # y axis grows downward (matches Worldgen's poisson coords).
      def compass(ax, ay, bx, by)
        dx = bx - ax
        dy = by - ay
        angle = Math.atan2(dy, dx) * 180.0 / Math::PI  # -180..180
        # 8 sectors, each 45°; offset so 0° (east) is centered in "E"
        idx = (((angle + 360 + 22.5) % 360) / 45).floor
        %w[E SE S SW W NW N NE][idx]
      end
    end
  end
end
