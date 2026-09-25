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
    # - PERSON claims only (v0). A claimed place goes through the one place
    #   door, Settlement::PlaceWriter; factions are rare enough to defer.
    # - KEEP THE SPOKEN NAME. The player heard "Harek"; the row must be Harek.
    #   This is the one mint path that does NOT mechanically rename (every other
    #   path drops the LLM name and assigns from the culture pools).
    # - Dedup is a global exact / first-token name match — "does this row already
    #   exist", not fuzzy semantic matching. On a hit we LINK, never duplicate.
    # - Placement: if the claim bound to a room, the person is homed THERE so
    #   they're present when the player walks in. Otherwise homed at the
    #   settlement root, awake — as findable as any citizen, no more. The
    #   social web (who-else-knows-them at the destination) is handled at
    #   scene entry by SocialWeb.
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
        # The player is a person in the room, never someone to realize: a
        # claim carrying their name would mint a namesake NPC (find_existing
        # sees NPC rows only).
        if (player = ::Player.first) && !spoken.empty? && name_match?(player.name, spoken)
          logger.info { "[NarrativeShift] claim #{spoken.inspect} names the player — not a referral" }
          return nil
        end

        named = proper_name?(spoken)
        if (existing = (named && find_existing(spoken)) || find_by_reference(spoken))
          logger.info { "[NarrativeShift] claim #{spoken.inspect} LINKS to existing character_id=#{existing.id} #{existing.name.inspect}" }
          return { "character_id" => existing.id, "name" => existing.name, "linked" => true }
        end

        # The claim's anchor place goes through the one place door: an
        # existing room by name or by the bind judge, a scenery kind minted
        # once per settlement, or nothing.
        at_name = claim["at_location"].to_s.strip
        place   = ::Harness::Settlement::PlaceWriter.resolve(name: at_name, context: context, source: :claim, logger: logger).location
        root    = ::Harness::Settlement::PlaceWriter.root_of(context.player_location)

        # The offices half of the person door, before any mint. The claim's
        # trade is the reflection's pick from the closed vocation list; the
        # town's own rows say who holds it — the keeper of the room the
        # claim anchors to, or for a civic office held once the room that
        # carries it (seeded now if it stands empty), a resident who holds
        # it, or nobody, and then the claim is refused rather than minted at
        # the root against the town's own doctrine. The spoken name yields
        # to the manifest here: two reeves stood in one hall, and a second
        # Varya beside the smith, when it did not (roster-2). A claim
        # anchored in another town is that town's business.
        unless place && place.parent_id.nil? && place.id != root&.id
          held = ::Harness::Settlement::Doctrine.holder(subrole, context.player_location, anchor: place, llm: context.llm_grunt, logger: logger)
          if held&.linked?
            logger.info { "[NarrativeShift] claim #{spoken.inspect} (#{subrole}) is #{root&.name}'s #{held.words}: LINKS character_id=#{held.npc.id} #{held.npc.name.inspect}" }
            return { "character_id" => held.npc.id, "name" => held.npc.name, "linked" => true }
          elsif held&.absent?
            logger.info { "[NarrativeShift] claim #{spoken.inspect} (#{subrole}): #{root&.name} has no #{held.words} — refused" }
            return nil
          end
        end

        role_ref = nil
        if named
          name = spoken
        else
          # A repeated role-reference resolved above through the stored
          # role_reference; a first one gets a real name from the picker —
          # a pool string dialogue will never say again, so the referring
          # EXPRESSION stays the stable key (the two-Guard-Captains bug).
          role_ref = spoken.presence
          name = ::Harness::Naming.unique_for(location: context.player_location)
          logger.info { "[NarrativeShift] claim by role #{spoken.inspect} → picker named #{name.inspect}" }
        end

        # A room the settlement was not laid out with is not talked into
        # existence: without an anchor the person is homed at the
        # settlement instead. A claim anchored at the player's CURRENT location describes this
        # scene's own furniture, not a findable person elsewhere — anyone
        # actually here has a row already. Minting duplicates the room (the
        # two-drovers bug), so refuse the claim outright.
        if place && place.id == context.player_location&.id
          logger.info { "[NarrativeShift] claim #{(spoken.presence || gist).inspect} anchored at the current location #{place.name.inspect} — scenery, refusing mint" }
          return nil
        end
        home    = place || ::Harness::Settlement::PlaceWriter.root_of(context.player_location)

        npc = ::Harness::Character::Hatchery.spawn(
          llm_grunt:        context.llm_grunt,
          name:             name,
          subrole:          subrole,
          location:         (place || home),
          home_location_id: home&.id,
          # No place anchor → homed at the settlement root, awake: findable
          # the way any citizen is (the street roll, the draws). Dormant
          # rows are skipped by whereabouts and woken only by the
          # materializer, so a dormant claim was a person nobody could find.
          dormant:          false,
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
          where = place ? place.name : "#{home&.name} (at large)"
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
      def name_match?(a, b)
        a_norm = a.to_s.strip.downcase
        b_norm = b.to_s.strip.downcase
        return false if a_norm.empty? || b_norm.empty?
        return true  if a_norm == b_norm
        return true  if a_norm == b_norm.split(/\s+/).first
        return true  if b_norm == a_norm.split(/\s+/).first
        false
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
        # The named-case trigger carries the SPEAKER — "tell him I sent you"
        # only pays off if the referrer's name is in the subject's memory text
        # (participants held Wenriel as source, but participants don't render
        # into prose). The role-ref trigger stays a bare alias: it is the
        # recall key ("the surveyor is Corin") and must not be reworded.
        trigger = role_ref ? "#{role_ref} is #{npc.name}" : "#{speaker_label(speaker)} named #{npc.name} to the player"
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
