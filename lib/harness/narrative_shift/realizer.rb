module Harness
  module NarrativeShift
    # GROUND v0 — realize a CLAIM into a grounded row.
    #
    # A "claim" is a specific named person an NPC introduced in this turn's
    # dialogue who has no row yet — the relay contact Vesna dispatches the
    # player to, the miller's named cousin, the smith two towns over. Left
    # alone, that name lives in one line of prose and nothing backs it: the
    # player travels there and "Harek" doesn't exist (the canonical ghost).
    # The conversation runner surfaces the claim as a thin seed; this consumer
    # turns it into a real, findable character.
    #
    # This is the RESCUE half (GROUND), not the generative half (ARM): it
    # captures a name the NPC already spoke, it does not encourage NPCs to
    # invent more. See memory project_narrative_shift_v2.
    #
    # Decisions baked in here:
    # - PERSON claims only (v0). Places are the worldbuilding runner's domain;
    #   factions are rare enough to defer.
    # - KEEP THE SPOKEN NAME. The player heard "Harek"; the row must be Harek.
    #   This is the one mint path that does NOT mechanically rename (every other
    #   path drops the LLM name and assigns from the culture pools).
    # - Dedup is a global exact / first-token name match — "does this row already
    #   exist", not fuzzy semantic matching. On a hit we LINK, never duplicate.
    # - Placement: if the NPC named a real destination, create the person THERE
    #   (active) so they're present when the player travels over. Otherwise
    #   UNPLACED + dormant — grounded and queryable, crowding no scene. The
    #   social web (who-else-knows-them at the destination) is deferred to that
    #   scene's entry passes (increment 2).
    # - The spawn runs the full Hatchery materialize (stats + description) — that
    #   IS the "mini genesis". Same cost profile as propose_character.
    module Realizer
      module_function

      # claim   : { "name", "subrole"?, "gist"?, "at_location"? }
      # speaker : the Character (NPC) whose dialogue made the claim
      # context : Turn::Context (llm_grunt, game_time, player handle)
      # → { character_id, name, minted|linked, ... } or nil on bad input / failure
      def run(claim:, speaker:, context:, logger: Rails.logger)
        return nil unless claim.is_a?(Hash)
        spoken  = claim["name"].to_s.strip
        gist    = claim["gist"].to_s.strip
        return nil if spoken.empty? && gist.empty? # nothing to realize

        subrole = claim["subrole"].to_s.strip
        subrole = "stranger" if subrole.empty?

        # NAME. Keep the NPC's spoken name only when it's a real name the player
        # heard ("Harek") — the one mint path that doesn't mechanical-rename. If
        # the NPC referred by ROLE ("the surveyor") or gave nothing, the name
        # picker assigns a real one. A role-reference is a valid person to spawn;
        # they just haven't been named in dialogue yet. Next turn the NPC recalls
        # the assigned name off the event log — no second spawn, no duplicate.
        role_ref = nil
        if proper_name?(spoken)
          name = spoken
          if (existing = find_existing(name) || find_by_reference(spoken))
            logger.info { "[NarrativeShift] claim #{name.inspect} LINKS to existing character_id=#{existing.id}" }
            return { "character_id" => existing.id, "name" => existing.name, "linked" => true }
          end
        else
          # A repeated role-reference must resolve to the row it already
          # realized to — the picker-assigned name is a pool string dialogue
          # will never say again, so the referring EXPRESSION is the only
          # stable key (the two-Guard-Captains bug).
          if (existing = find_by_reference(spoken))
            logger.info { "[NarrativeShift] role ref #{spoken.inspect} LINKS to existing character_id=#{existing.id} #{existing.name.inspect}" }
            return { "character_id" => existing.id, "name" => existing.name, "linked" => true }
          end
          role_ref = spoken.presence
          name = ::Harness::Naming.unique_for(location: context.player_location)
          logger.info { "[NarrativeShift] claim by role #{spoken.inspect} → picker named #{name.inspect}" }
        end

        at_name = claim["at_location"].to_s.strip
        # The claim's anchor place is realized WITH the claim (no parking, no
        # lazy placement): reuse an existing row when one matches, else mint
        # the sublocation NOW so the person is home and findable the moment
        # they're spoken of — and so a later "go to the mill" is plain
        # movement instead of the worldbuilder inventing a second mill with
        # a second miller.
        place   = resolve_or_mint_location(at_name, context, logger)
        home    = place || settlement_for(context.player_location)

        npc = ::Harness::Character::Hatchery.spawn(
          llm_grunt:        context.llm_grunt,
          name:             name,
          subrole:          subrole,
          location:         (place || home),
          home_location_id: home&.id,
          dormant:          place.nil?, # no place anchor → off the current stage, still homed
          properties:       {
            "claimed_by"        => speaker_label(speaker),
            "claim_gist"        => gist.presence,
            "role_reference"    => role_ref,
            "claim_pending_web" => true
          }.compact,
          prose_context:    gist.presence || "named by #{speaker_label(speaker)} in conversation with the player"
        )

        event = ground_event(npc, speaker, context, gist, role_ref)
        logger.info do
          where = place ? place.name : "#{home&.name} (dormant local)"
          via   = role_ref ? " (role #{role_ref.inspect} → #{name.inspect})" : ""
          "[NarrativeShift] claim MINTED character_id=#{npc.id} #{name.inspect}#{via} at #{where} (event_id=#{event&.id})"
        end
        {
          "character_id" => npc.id, "name" => npc.name, "subrole" => npc.subrole,
          "location_id" => npc.location_id, "minted" => true, "event_id" => event&.id
        }
      rescue StandardError => e
        logger.warn { "[NarrativeShift] realize failed for #{claim.inspect}: #{e.class}: #{e.message}" }
        nil
      end

      # Global "does this person already exist" check. Exact case-insensitive
      # first (the common Harek == Harek dup), then a bounded first-token sweep
      # (Harek == "old Harek"). NOT fuzzy/semantic — that's a deliberate
      # non-goal (the harbormaster-vs-Doran case stays a bitten edge).
      def find_existing(name)
        exact = ::Npc.where("LOWER(name) = ?", name.downcase).first
        return exact if exact
        ::Npc.where("LOWER(name) LIKE ?", "#{name.downcase.split(/\s+/).first} %").find { |c| name_match?(c.name, name) } ||
          ::Npc.where("LOWER(name) LIKE ?", "% #{name.downcase}").find { |c| name_match?(c.name, name) }
      end

      # Resolve a referring expression against rows it may have already
      # realized to: the stored `role_reference` of a past role-mint, or a
      # role-shaped NAME (a first mention like "Guard-Captain" that slipped
      # the proper_name? gate and became the row's literal name). Leading
      # articles stripped on both sides, so "the Guard-Captain" ==
      # "Guard-Captain" == role_reference "The Guard-Captain". Exact after
      # normalization — deliberately NOT fuzzy, same policy as find_existing.
      def find_by_reference(ref)
        key = reference_key(ref)
        return nil if key.empty?
        ::Npc.find_each.find do |c|
          stored = c.properties.is_a?(Hash) ? c.properties["role_reference"] : nil
          reference_key(stored) == key || reference_key(c.name) == key
        end
      end

      def reference_key(s)
        tokens = s.to_s.strip.downcase.split(/\s+/)
        tokens.shift while tokens.first && ARTICLES.include?(tokens.first)
        tokens.join(" ")
      end

      # Did the NPC actually NAME this person, or refer to them by role? Decides
      # keep-the-spoken-name vs let-the-picker-name — NOT accept vs reject (a
      # role-reference is still a real person to spawn). A real name starts
      # capitalized, leads with no article, and is short. "Corin"/"Mad Jenny"/
      # "Old Harek" → keep; "the surveyor"/"a stranger"/"the highest pile of the
      # first crossing point in the marsh" → picker assigns a name.
      ARTICLES = %w[the a an some that this].freeze
      def proper_name?(name)
        n = name.to_s.strip
        return false if n.empty?
        return false unless n[0] =~ /[[:upper:]]/
        tokens = n.split(/\s+/)
        return false if tokens.length > 4
        return false if ARTICLES.include?(tokens.first.downcase)
        true
      end

      # The settlement a claimed person calls home when no real destination was
      # named: walk up to the nearest residence (settlement/lair), else the
      # top-level location. Everyone gets a home — no floating, locationless names.
      def settlement_for(location)
        return nil unless location
        loc = location
        loc = loc.parent while loc.parent && !loc.residence?
        loc
      end

      # Is this a place NAME we can sensibly park for later relocation, vs prose?
      # A clean name is short ("Blackwood Relay"); "the highest pile of the first
      # crossing point in the marsh" is a description and won't ever match a row.
      def looks_like_place?(s)
        n = s.to_s.strip
        !n.empty? && n.split(/\s+/).length <= 5
      end

      def name_match?(a, b)
        a_norm = a.to_s.strip.downcase
        b_norm = b.to_s.strip.downcase
        return false if a_norm.empty? || b_norm.empty?
        return true  if a_norm == b_norm
        return true  if a_norm == b_norm.split(/\s+/).first
        return true  if b_norm == a_norm.split(/\s+/).first
        false
      end

      # Resolve the claim's anchor place, EAGERLY (no parking): exact name
      # match anywhere → reuse; a head-noun match among the current
      # settlement's sublocations → reuse ("the mill" IS the existing Tide
      # Mill — one mill per town); else, if it reads as a clean place name,
      # MINT it now as a sublocation of the current settlement. Prose
      # descriptions ("the highest pile of the first crossing…") mint nothing.
      def resolve_or_mint_location(at_location, context, logger)
        nm = at_location.to_s.strip
        return nil if nm.empty?
        exact = ::Location.where("LOWER(name) = ?", nm.downcase).first
        return exact if exact

        settlement = root_settlement(context.player_location)
        return nil unless settlement
        if (existing = head_noun_match(nm, settlement))
          logger.info { "[NarrativeShift] anchor #{nm.inspect} matches existing #{existing.name.inspect} — reusing" }
          return existing
        end
        return nil unless looks_like_place?(nm)

        loc = ::Location.create!(
          name:        titleize_place(nm),
          description: "A place in #{settlement.name}, spoken of in passing.",
          parent:      settlement
        )
        logger.info { "[NarrativeShift] anchor MINTED location_id=#{loc.id} #{loc.name.inspect} under #{settlement.name}" }
        loc
      end

      # Anchors parent at the ROOT settlement (the town), matching the
      # PlaceRealizer's convention — settlement_for (person homing) can stop
      # at a residence like a tavern, which is no parent for a mill.
      def root_settlement(location)
        return nil unless location
        loc = location
        loc = loc.parent while loc.parent
        loc
      end

      # "the mill" ~ "the Tide Mill": both head nouns are "mill". Token-exact
      # on the final word (articles stripped) — deliberately not fuzzy, so
      # "the sawmill" never collapses into "the mill".
      def head_noun_match(nm, settlement)
        key = reference_key(nm).split(" ").last.to_s
        return nil if key.empty?
        ::Location.where(parent_id: settlement.id).to_a
                  .find { |l| reference_key(l.name).split(" ").last == key }
      end

      def titleize_place(nm)
        nm.split(/\s+/).map.with_index { |w, i|
          i.zero? && ARTICLES.include?(w.downcase) ? w.downcase : w.capitalize
        }.join(" ")
      end

      # The SHARED event tying the speaker to the new person — the "tangent" that
      # lets the speaker RECALL them next turn (and, when role-named, recall the
      # picked name from the role: "the surveyor is Corin"). Surfaces via
      # query_events(for_holder_id: speaker.id); speaker + subject + player
      # tagged. Non-fatal if the append fails.
      def ground_event(npc, speaker, context, gist, role_ref = nil)
        parts = [ { character: npc, role: "subject" } ]
        parts << { character: speaker, role: "source" } if speaker.respond_to?(:id)
        if (player = ::Player.first)
          parts << { character: player, role: "recipient" }
        end
        trigger = role_ref ? "#{role_ref} is #{npc.name}" : "named #{npc.name} to the player"
        body    = [ role_ref, gist.presence ].compact.join(" — ")
        body    = "#{speaker_label(speaker)} spoke of #{npc.name}" if body.empty?
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  context.player_location,
          details: {
            "narrative" => { "trigger" => trigger, "details" => body }
          },
          participants: parts
        )
      rescue StandardError
        nil
      end

      def speaker_label(speaker)
        speaker.respond_to?(:name) ? speaker.name : "an NPC"
      end
    end
  end
end
