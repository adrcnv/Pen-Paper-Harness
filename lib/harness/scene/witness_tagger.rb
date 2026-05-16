module Harness
  module Scene
    # Mechanical, LLM-free pass at scene exit. For every event committed at
    # this scene's location during this scene's lifetime, tag every
    # present_character not already in the participant list as role:
    # "witness". Closes the structural gap from co-location's retirement:
    # side characters in a scene get belief access to events they observed,
    # without the witness inference being an LLM judgment call.
    #
    # Why mechanical, not LLM-judged: presence-during-scene is a structural
    # fact (we know who was at this location for this scene's window). The
    # LLM doesn't need to judge "did the barkeep see the brawl?" — if the
    # barkeep was at the tavern when the brawl was committed, he saw it. Cheaper,
    # more predictable, no per-scene-exit LLM tax.
    #
    # Replaces the prior Scene::Extractor (LLM-driven extraction of
    # characters / factions / ignorance / telling-events from narration).
    # The narration step is now disciplined: it doesn't invent nouns. The
    # reasoning loop owns all entity creation via tools. Extraction's only
    # remaining structural job — "who silently witnessed what" — collapses
    # to this tagger.
    class WitnessTagger
      def self.tag(scene_active, current_game_time, logger: Rails.logger)
        new(scene_active, current_game_time, logger).tag
      end

      def initialize(scene_active, current_game_time, logger)
        @scene             = scene_active
        @current_game_time = current_game_time
        @logger            = logger
      end

      def tag
        location = @scene.location
        present  = @scene.present_characters
        return 0 if present.empty?

        floor = @scene.entered_at_game_time || 0
        events = ::Event.where(location_id: location.id)
                        .where(game_time: floor..@current_game_time)
                        .to_a
        return 0 if events.empty?

        added = 0
        ::ActiveRecord::Base.transaction do
          events.each do |ev|
            existing_ids = ev.event_participants.pluck(:character_id).compact.to_set
            present.each do |char|
              next if existing_ids.include?(char.id)
              ::EventParticipant.create!(event: ev, character: char, role: "witness")
              added += 1
            end
          end
        end
        @logger.info { "[WitnessTagger] tagged #{added} witness(es) on #{events.size} event(s) at #{location.name}" }
        added
      end
    end
  end
end
