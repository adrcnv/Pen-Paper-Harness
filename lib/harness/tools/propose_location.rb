module Harness
  module Tools
    # Promote a place into a Location row. Two flavors:
    #
    #   sublocation     — a place INSIDE an existing parent (a tavern, a guildhouse,
    #                     a market wing). parent_id required. No x/y/biome (those
    #                     are properties of the top-level place; sublocations
    #                     inherit reach through parent_id).
    #
    #   wilderness_leaf — a NEW top-level place out in the world (a wayshrine,
    #                     a ruin, a bandit camp). Coords sampled near the
    #                     player's current top-level position via rejection
    #                     sampling (avoiding existing cities), biome inherited
    #                     from the nearest neighbor (the worldgen seed isn't
    #                     persisted, so we can't re-sample the noise field —
    #                     see CLAUDE.md). Tagged with `properties.kind =
    #                     "wilderness_leaf"` so the auto-Materializer at scene
    #                     entry knows to spawn NPCs at this row (worldgen
    #                     cities don't get the tag — their NPCs live in
    #                     sublocations).
    #
    # Prose backfill runs on every successful promotion: any prior Event with
    # details["location_name"] == name gets its location_id set and the
    # location_name prose field cleared. This is the location-side analog of
    # class-2 → class-4 actor promotion.
    class ProposeLocation < Base
      TYPE_SUBLOCATION     = "sublocation".freeze
      TYPE_WILDERNESS_LEAF = "wilderness_leaf".freeze
      ALLOWED_TYPES        = [ TYPE_SUBLOCATION, TYPE_WILDERNESS_LEAF ].freeze

      MIN_NEW_DIST  = 6.0   # rejection radius vs existing top-level when sampling
      SAMPLE_MIN    = 8.0   # min distance from player anchor
      SAMPLE_MAX    = 35.0  # max distance from player anchor
      MAX_ATTEMPTS  = 60

      def self.tool_name
        "propose_location"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Promote a place into a Location row. Use AFTER query_location_by_name confirms no row exists. type=#{TYPE_SUBLOCATION.inspect} for places INSIDE an existing parent (parent_id required); type=#{TYPE_WILDERNESS_LEAF.inspect} for NEW top-level places out in the world (coords sampled near the player automatically, biome inherited from nearest neighbor). Backfills prior event prose (any event with details.location_name == name gets its location_id set on this row).",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "name"        => { "type" => "string", "description" => "display name (must be unique among Locations)" },
              "description" => { "type" => "string", "description" => "one or two sentences describing the place" },
              "type"        => { "type" => "string", "enum" => ALLOWED_TYPES, "description" => "sublocation (inside a parent) or wilderness_leaf (new top-level)" },
              "parent_id"   => { "type" => "integer", "description" => "required when type=sublocation; the containing Location" },
              "connection"  => { "type" => "string", "description" => "free-text rationale grounding this place in surrounding state ('the warehouse Korr mentioned', 'a wayshrine across the river from Saltmere')" }
            },
            "required" => [ "name", "description", "type", "connection" ]
          }
        }
      end

      def call(args, context)
        name        = args["name"]
        description = args["description"]
        type        = args["type"]
        parent_id   = args["parent_id"]
        connection  = args["connection"]

        return { "error" => "name must be a non-empty string" }        unless name.is_a?(String) && !name.strip.empty?
        return { "error" => "description must be a non-empty string" } unless description.is_a?(String) && !description.strip.empty?
        return { "error" => "connection must be a non-empty string" }  unless connection.is_a?(String) && !connection.strip.empty?
        return { "error" => "type must be one of #{ALLOWED_TYPES.inspect}" } unless ALLOWED_TYPES.include?(type)
        return { "error" => "name #{name.inspect} already exists as a Location" } if ::Location.exists?(name: name)

        case type
        when TYPE_SUBLOCATION     then create_sublocation(name, description, parent_id, connection, context)
        when TYPE_WILDERNESS_LEAF then create_wilderness_leaf(name, description, connection, context)
        end
      end

      private

      def create_sublocation(name, description, parent_id, connection, context)
        return { "error" => "parent_id is required for type=sublocation" } unless parent_id.is_a?(Integer)
        parent = ::Location.find_by(id: parent_id)
        return { "error" => "no location with id=#{parent_id}" } unless parent

        loc = nil
        backfilled = 0
        ::ActiveRecord::Base.transaction do
          loc = ::Location.create!(
            name:        name,
            description: description,
            parent:      parent
          )
          backfilled = backfill_prose(name, loc.id)
        end

        intro_event = log_introduction(loc, parent, connection, context, scope: "personal")

        {
          "location_id"       => loc.id,
          "name"              => loc.name,
          "type"              => TYPE_SUBLOCATION,
          "parent_id"         => parent.id,
          "events_backfilled" => backfilled,
          "event_id"          => intro_event.id,
          "game_time"         => context.game_time,
          "committed_summary" => "[committed location_id=#{loc.id}] #{loc.name} (sublocation of #{parent.name}) — #{description.to_s[0, 100]}"
        }
      end

      def create_wilderness_leaf(name, description, connection, context)
        anchor = top_level_with_coords(context.player_location)
        return { "error" => "cannot place a wilderness_leaf — player is not at a top-level location with coordinates (worldgen-rooted required)" } unless anchor

        existing = ::Location.where(parent_id: nil).where.not(x: nil, y: nil).to_a
        coords   = sample_coords(anchor, existing)
        return { "error" => "could not place wilderness_leaf without colliding with existing locations after #{MAX_ATTEMPTS} attempts" } unless coords

        x, y = coords
        biome = nearest_biome(x, y, existing) || ::Harness::Worldgen::Biome::LOWLAND

        loc = nil
        backfilled = 0
        ::ActiveRecord::Base.transaction do
          loc = ::Location.create!(
            name:        name,
            description: description,
            x:           x,
            y:           y,
            biome:       biome,
            properties:  { "kind" => TYPE_WILDERNESS_LEAF }
          )
          backfilled = backfill_prose(name, loc.id)
        end

        intro_event = log_introduction(loc, anchor, connection, context, scope: "local")

        # Genesis is intentionally NOT run for wilderness_leafs. The places
        # are typically ephemeral (encounter-spawned, transient) and back-
        # generating 0-5 past events spends tokens for texture the player
        # will rarely revisit. Worldgen cities still get genesis-on-entry
        # via Scene::Manager. Reinstate per-leaf genesis only when there's
        # a real need.
        {
          "location_id"       => loc.id,
          "name"              => loc.name,
          "type"              => TYPE_WILDERNESS_LEAF,
          "x"                 => loc.x,
          "y"                 => loc.y,
          "biome"             => loc.biome,
          "events_backfilled" => backfilled,
          "event_id"          => intro_event.id,
          "game_time"         => context.game_time,
          "committed_summary" => "[committed location_id=#{loc.id}] #{loc.name} (wilderness_leaf, #{loc.biome}) — #{description.to_s[0, 100]}"
        }
      end

      # Rejection sampling — pick a point in [SAMPLE_MIN, SAMPLE_MAX] from the
      # anchor that is at least MIN_NEW_DIST from every existing top-level.
      def sample_coords(anchor, existing)
        rng = Random.new
        MAX_ATTEMPTS.times do
          angle  = rng.rand * 2 * Math::PI
          radius = SAMPLE_MIN + rng.rand * (SAMPLE_MAX - SAMPLE_MIN)
          x = anchor.x + radius * Math.cos(angle)
          y = anchor.y + radius * Math.sin(angle)
          too_close = existing.any? { |loc| Math.hypot(loc.x - x, loc.y - y) < MIN_NEW_DIST }
          return [ x.round(2), y.round(2) ] unless too_close
        end
        nil
      end

      def nearest_biome(x, y, existing)
        nearest = existing.min_by { |loc| Math.hypot(loc.x - x, loc.y - y) }
        nearest&.biome
      end

      # Find any prior events whose prose referenced this name (via
      # details.location_name), set their location_id to the new row, clear
      # the prose field. Returns the count of events updated.
      def backfill_prose(name, new_id)
        rows = ::Event.where("json_extract(details, '$.location_name') = ?", name)
        count = 0
        rows.find_each do |ev|
          details = ev.details.is_a?(Hash) ? ev.details.dup : {}
          details.delete("location_name")
          ev.update!(location_id: new_id, details: details)
          count += 1
        end
        count
      end

      def log_introduction(loc, anchor, connection, context, scope:)
        kind = loc.parent_id ? "sublocation" : "wilderness_leaf"
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time,
          scope:     scope,
          location:  loc,
          details: {
            "introduction" => {
              "target_type" => "location",
              "target_id"   => loc.id,
              "target_name" => loc.name,
              "kind"        => kind,
              "connection"  => connection,
              "anchor"      => anchor&.name
            },
            # Surfaced via Event.queryable for NPC speech sourcing — see
            # propose_character for the rationale.
            "narrative" => {
              "trigger" => "introduced #{kind}",
              "details" => connection
            }
          },
          participants: []
        )
      end

      def top_level_with_coords(loc)
        current = loc
        while current
          return current if current.x.present? && current.y.present? && current.parent_id.nil?
          current = current.parent
        end
        nil
      end
    end
  end
end
