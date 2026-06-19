module Harness
  module Scene
    # Resolves pending_appearance rows at scene entry: queries unresolved rows
    # targeting the player that are firable now and in scope of the current
    # location, then realizes each by relocating a known character or
    # spawning a fresh class-4 from a faceless faction origin. Marks each
    # resolved.
    #
    # Pure structural — no LLM. The intent_text from the appearance row is
    # written to character.properties.appearance_intent so InternalState
    # synthesis can pick it up and surface the hook in narration.
    #
    # Post-Phase-2: the class-2 promote path is gone. Genesis eager-spawns
    # class-4 rows for every named historical at creation time, so a
    # pending_appearance referencing a genesis figure already has an
    # actor_character_id pointing at a real (dormant) row. Resolution
    # relocates that row and clears its dormant flag.
    #
    # Failure modes:
    #   - row with no actor specifier and no faction → logged, skipped
    #   - relocation/spawn that raises               → logged, skipped (other rows still resolve)
    #
    # Returns array of Outcome structs in the order resolved.
    class PendingAppearanceResolver
      Outcome = Struct.new(:appearance, :character, :kind, keyword_init: true)

      # llm_grunt is passed through to Hatchery for stat materialization on
      # the path that creates fresh rows (spawn_faceless). Optional: when
      # nil, Hatchery falls back to default stats — resolution still
      # completes structurally.
      def initialize(llm_grunt: nil, logger: Rails.logger)
        @llm_grunt = llm_grunt
        @logger    = logger
      end

      def resolve(target_character:, current_location:, current_game_time:)
        return [] unless target_character && current_location

        candidates = ::PendingAppearance
                       .for_target(target_character)
                       .unresolved
                       .firable_at(current_game_time)
                       .to_a

        eligible = candidates.select { |pa| in_scope?(pa, current_location) }
        return [] if eligible.empty?

        @logger.info { "[Scene::PendingAppearanceResolver] target=#{target_character.name} location=#{current_location.name} candidates=#{candidates.size} eligible=#{eligible.size}" }

        outcomes = []
        ::ActiveRecord::Base.transaction do
          eligible.each do |pa|
            outcome = realize(pa, current_location)
            next unless outcome
            pa.resolve!(current_game_time)
            outcomes << outcome
          end
        end
        outcomes
      end

      private

      def in_scope?(pa, current_location)
        case pa.scope
        when "anywhere"
          true
        when "local"
          pa.anchor_location_id == current_location.id
        when "city"
          a = pa.anchor_location
          return false unless a
          c = current_location
          c.id == a.id ||
            c.parent_id == a.id ||
            c.id == a.parent_id ||
            (c.parent_id && c.parent_id == a.parent_id)
        else
          false
        end
      end

      def realize(pa, current_location)
        if pa.actor_character_id.present?
          relocate(pa, current_location)
        elsif pa.origin_faction_id.present?
          spawn_faceless(pa, current_location)
        else
          @logger.warn { "[Scene::PendingAppearanceResolver] PA##{pa.id} has no actor specifier or faction; skipping" }
          nil
        end
      rescue StandardError => e
        @logger.warn { "[Scene::PendingAppearanceResolver] PA##{pa.id} realize failed: #{e.class}: #{e.message}" }
        nil
      end

      # Relocate a known character to the current location, clearing
      # dormant if set (the PA is the wake trigger for genesis-spawned
      # dormant historicals) and merging the intent text.
      def relocate(pa, current_location)
        char = pa.actor_character
        props = char.properties.is_a?(Hash) ? char.properties.dup : {}
        was_dormant = props["dormant"] == true
        props.delete("dormant")
        props["appearance_intent"] = pa.intent_text
        char.update!(location_id: current_location.id, properties: props)
        kind = was_dormant ? :woke : :relocated
        @logger.info { "[Scene::PendingAppearanceResolver] PA##{pa.id} #{kind} #{char.name} -> #{current_location.name}" }
        Outcome.new(appearance: pa, character: char, kind: kind)
      end

      def spawn_faceless(pa, current_location)
        faction = pa.origin_faction
        base    = "#{faction.name} emissary"
        name    = unique_name(base)
        props   = {
          "appearance_intent" => pa.intent_text,
          "faction_id"        => faction.id
        }
        char = ::Harness::Character::Hatchery.spawn(
          llm_grunt:     @llm_grunt,
          name:          name,
          subrole:       faction.subrole || "stranger",
          location_id:   current_location.id,
          home_location_id: (current_location.residence? ? current_location.id : nil),
          properties:    props,
          prose_context: "Sent by #{faction.name} (#{faction.subrole}). #{pa.intent_text}"
        )
        @logger.info { "[Scene::PendingAppearanceResolver] PA##{pa.id} spawned faceless '#{name}' (faction=#{faction.name}) at #{current_location.name}" }
        Outcome.new(appearance: pa, character: char, kind: :spawned)
      end

      def unique_name(base)
        return base unless ::Character.exists?(name: base)
        i = 2
        loop do
          candidate = "#{base} (#{i})"
          return candidate unless ::Character.exists?(name: candidate)
          i += 1
        end
      end
    end
  end
end
