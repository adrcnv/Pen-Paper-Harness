module Harness
  module NarrativeShift
    # Increment-2 social web — when a claimed person is first present in a scene
    # with other NPCs, make a few of those NPCs KNOW them, so "ask around at the
    # relay" pays off (the keeper points the player to Harek instead of shrugging).
    #
    # This is the WIRING half, kept deliberately mechanical: it does NOT invent
    # who the claimed person is — that identity was captured at claim time and
    # rides on `properties.claim_gist`. Here we only tie the carried identity to
    # the LOCAL cast (which only exists at the destination). Each tie is a
    # `local`-scope awareness event with the knower + subject as participants, so
    # query_events(for_holder_id: knower) surfaces it and the conversation runner
    # can have the knower speak to it.
    #
    # Runs from Scene::Manager#enter AFTER the snapshot (so present NPCs are
    # known). Idempotent via the `claim_pending_web` flag: woven once, cleared.
    # If no other NPC is present yet, we defer (leave the flag) for a later entry
    # when the place is populated. Heavily logged — a scrutinised seam.
    module SocialWeb
      MAX_KNOWERS = 2

      module_function

      # present : snapshot.present_characters (Npc rows at this location)
      # context : Turn::Context (game_time, player_location)
      def weave!(present, context, logger: Rails.logger)
        present = Array(present)
        subjects = present.select { |c| pending_web?(c) }
        return [] if subjects.empty?

        woven = []
        subjects.each do |subject|
          knowers = pick_knowers(subject, present)
          if knowers.empty?
            logger.info { "[NarrativeShift::SocialWeb] #{subject.name} (id=#{subject.id}) alone here — deferring web (flag kept)" }
            next
          end
          knowers.each { |k| commit_awareness(k, subject, context, logger) }
          clear_flag!(subject)
          logger.info { "[NarrativeShift::SocialWeb] wove #{subject.name} (id=#{subject.id}) into #{knowers.map(&:name).inspect}" }
          woven << subject
        end
        woven
      rescue StandardError => e
        logger.warn { "[NarrativeShift::SocialWeb] weave failed: #{e.class}: #{e.message}" }
        []
      end

      # Prefer established locals (not other fresh claims, not the subject) so a
      # claim isn't wired only to another claim. Fall back to any other present
      # NPC if that leaves nobody.
      def pick_knowers(subject, present)
        others = present.reject { |c| c.id == subject.id || dormant?(c) }
        grounded = others.reject { |c| pending_web?(c) }
        pool = grounded.any? ? grounded : others
        pool.first(MAX_KNOWERS)
      end

      def commit_awareness(knower, subject, context, logger)
        gist = subject_gist(subject)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "local",
          location:  context.player_location,
          details: {
            "narrative" => {
              "trigger" => "knows #{subject.name}",
              "details" => "#{knower.name} knows of #{subject.name} — #{gist}"
            }
          },
          participants: [
            { character: knower,  role: "knower" },
            { character: subject, role: "subject" }
          ]
        )
        logger.debug { "[NarrativeShift::SocialWeb] #{knower.name} ← knows → #{subject.name}" }
      rescue StandardError => e
        logger.warn { "[NarrativeShift::SocialWeb] awareness commit failed (#{knower.name}→#{subject.name}): #{e.class}: #{e.message}" }
      end

      def subject_gist(subject)
        props = subject.properties
        g = props.is_a?(Hash) ? props["claim_gist"].to_s.strip : ""
        g.empty? ? "they are expected here" : g
      end

      def clear_flag!(subject)
        props = subject.properties.is_a?(Hash) ? subject.properties.dup : {}
        props.delete("claim_pending_web")
        subject.update!(properties: props)
      end

      def pending_web?(c)
        c.properties.is_a?(Hash) && c.properties["claim_pending_web"] == true
      end

      def dormant?(c)
        c.properties.is_a?(Hash) && c.properties["dormant"] == true
      end
    end
  end
end
