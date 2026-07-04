module Harness
  module NarrativeShift
    # Eager building realization — the place-side twin of Realizer (people).
    #
    # When an NPC names a specific place that has no row ("the Grand Hall", "the
    # Salt Wharf", "Corin's Forge"), that place lives in one line of prose and
    # nothing backs it. This mints it into a real, findable Location so the player
    # can be sent there.
    #
    # Deliberately NARROW — this is not the worldbuilding runner:
    # - SUBLOCATIONS ONLY, parented under the scene's root settlement (the town
    #   the player is in). No coords, no biome, no genesis — a conversation
    #   mention carries no geography, and a building lives inside the town. New
    #   top-level / wilderness places stay the worldbuilding runner's job.
    # - PROPER NAMES ONLY. A generic definite reference ("the mill", "the market",
    #   "the square") is rejected up front: those either already exist under a
    #   real name or aren't places, and minting them dupes the town's own rooms.
    # - Dedup is an exact case-insensitive name match → LINK, never duplicate.
    #   Fuzzy/semantic dedup is a deliberate non-goal (heaped).
    module PlaceRealizer
      module_function

      ARTICLES = %w[the a an some that this].freeze

      # place   : { "name", "about"?, "parent"? }
      # context : Turn::Context (player_location, game_time)
      # → { location_id, name, minted|linked } or nil (rejected / failure)
      def run(place:, context:, logger: Rails.logger)
        return nil unless place.is_a?(Hash)
        name = place["name"].to_s.strip
        return nil if name.empty?

        # LINK first — an existing place matches regardless of case or how
        # generically it was echoed ("the grand hall" → The Grand Hall).
        if (existing = ::Location.where("LOWER(name) = ?", name.downcase).first)
          logger.info { "[NarrativeShift::PlaceRealizer] #{name.inspect} LINKS to existing location_id=#{existing.id}" }
          return { "location_id" => existing.id, "name" => existing.name, "linked" => true }
        end

        # MINT gate — only a proper name coins a NEW row (the dupe guard).
        return nil unless proper_name?(name)
        return nil if ::Faction.exists?(name: name) # don't shadow a kingdom/guild name

        parent = resolve_parent(place["parent"], context)
        return nil unless parent

        loc = ::Location.create!(
          name:        name,
          description: place["about"].to_s.strip.presence || "A place in #{parent.name}, mentioned in passing.",
          parent:      parent
        )
        event = ground_event(loc, parent, context)
        logger.info { "[NarrativeShift::PlaceRealizer] MINTED location_id=#{loc.id} #{name.inspect} under #{parent.name} (event_id=#{event&.id})" }
        { "location_id" => loc.id, "name" => loc.name, "parent_id" => parent.id, "minted" => true }
      rescue StandardError => e
        logger.warn { "[NarrativeShift::PlaceRealizer] realize failed for #{place.inspect}: #{e.class}: #{e.message}" }
        nil
      end

      # A mintable place name is SPECIFIC enough not to shadow a settlement's
      # generic rooms: after stripping any leading article, it carries either a
      # capitalized (proper-noun) word OR a possessive qualifier. This is the
      # whole dupe guard — it accepts "The Grand Hall" / "Corin's Forge" /
      # "the founder's place" but rejects the bare generic references ("the mill",
      # "the market") that would collide with rooms every town already has.
      def proper_name?(name)
        tokens = name.to_s.strip.split(/\s+/)
        return false if tokens.empty? || tokens.length > 5
        meaningful = ARTICLES.include?(tokens.first.downcase) ? tokens[1..] : tokens
        return false if meaningful.nil? || meaningful.empty?
        meaningful.any? { |t| t[0] =~ /[[:upper:]]/ || t.include?("'") }
      end

      # Parent under a NAMED existing location if the NPC placed it somewhere real
      # ("the forge at Redmarsh" when Redmarsh is a row); otherwise under the
      # scene's root settlement (the town the player is standing in). Never a
      # floating top-level row.
      def resolve_parent(parent_name, context)
        nm = parent_name.to_s.strip
        if !nm.empty? && (loc = ::Location.where("LOWER(name) = ?", nm.downcase).first)
          return loc
        end
        root_settlement(context.player_location)
      end

      def root_settlement(location)
        return nil unless location
        loc = location
        loc = loc.parent while loc.parent
        loc
      end

      # The introduction event — mirrors ProposeLocation's, so the minted place is
      # queryable/sourceable like any other. Non-fatal.
      def ground_event(loc, parent, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "local",
          location:  loc,
          details: {
            "introduction" => {
              "target_type" => "location", "target_id" => loc.id,
              "target_name" => loc.name, "kind" => "sublocation",
              "connection" => "mentioned in conversation", "anchor" => parent.name
            },
            "narrative" => { "trigger" => "mentioned in conversation", "details" => "#{loc.name} in #{parent.name}" }
          },
          participants: []
        )
      rescue StandardError
        nil
      end
    end
  end
end
