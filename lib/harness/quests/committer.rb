module Harness
  module Quests
    # Takes a validated, hydrated authoring payload + the archetype + the city
    # and commits the whole quest end-to-end inside one transaction.
    #
    # Post-Phase-2 pipeline:
    #   1. Create the two fresh sublocations (giver + antagonist) as children
    #      of the city.
    #   2. Spawn each FRESH character (no LLM name — assigned mechanically
    #      via Harness::Naming at the right location) at their placement.
    #   3. Resolve each REUSED character from `existing_character_id` (rows
    #      stay where they live; we don't relocate them).
    #   4. Build a per-slot resolution table combining fresh + reused, in
    #      `characters[]`-then-`reused_characters[]` declaration order.
    #   5. Create each item, anchored at its slotted sublocation.
    #   6. Commit the backward kickoff event at the giver's fresh sublocation
    #      with all kickoff_participant_slots resolved to character rows.
    #      Fresh sublocation → empty after-set → BackwardAppender's validator
    #      is skipped.
    #   7. Insert the Quest row + steps, resolving archetype step targets
    #      against the slot map.
    #
    # Raises on any structural failure (rolls back).
    class Committer
      class CommitError < StandardError; end

      def self.commit(**kwargs)
        new(**kwargs).commit
      end

      def initialize(hydrated:, archetype:, city:, current_game_time:, llm_grunt: nil, rng: Random.new, logger: ::Rails.logger)
        @hydrated          = hydrated
        @archetype         = archetype
        @city              = city
        @current_game_time = current_game_time
        @llm_grunt         = llm_grunt
        @rng               = rng
        @logger            = logger
      end

      def commit
        ::ActiveRecord::Base.transaction do
          location_by_slot   = create_locations
          character_by_slot  = create_and_resolve_characters(location_by_slot)
          item_by_slot_index = create_items(location_by_slot)

          kickoff_event = commit_kickoff_event(location_by_slot, character_by_slot)

          giver = character_by_slot["giver[0]"] || character_by_slot["giver"]
          raise CommitError, "no giver character resolved" unless giver

          quest = ::Quest.create!(
            name:                @hydrated[:name],
            summary:              @hydrated[:summary],
            archetype_id:         @archetype["id"],
            state:                "offered",
            giver_character_id:   giver.id,
            city_location_id:     @city.id,
            created_event_id:     kickoff_event.id
          )

          create_steps(
            quest:                   quest,
            character_by_slot_index: character_by_slot,
            item_by_slot_index:      item_by_slot_index,
            location_by_slot:        location_by_slot,
            kickoff_event:           kickoff_event
          )

          @logger.info { "[Quest::Committer] committed quest ##{quest.id} #{quest.name.inspect} at city=#{@city.name} archetype=#{@archetype['id']} giver=#{giver.name}" }
          quest
        end
      end

      private

      def create_locations
        out = {}
        @hydrated[:locations].each do |l|
          loc = ::Location.create!(
            name:        l["name"],
            description: l["description"],
            parent:      @city,
            properties:  { "kind" => "quest_sublocation", "quest_slot" => l["slot"] }
          )
          out[l["slot"]] = loc
        end
        out
      end

      # Returns a slot-index → Character map combining fresh spawns (with
      # mechanical names) and reused existing rows. Per-slot ordering:
      # fresh entries come first in declaration order, then reused entries
      # in declaration order. So for a slot with 2 fills (1 fresh, 1 reused):
      #   "supporters[0]" → fresh
      #   "supporters[1]" → reused
      def create_and_resolve_characters(location_by_slot)
        # First pass: spawn fresh.
        fresh_by_slot = Hash.new { |h, k| h[k] = [] }
        @hydrated[:characters].each do |c|
          loc = case c["placement"]
                when "city"                  then @city
                when "giver_sublocation"     then location_by_slot.fetch("giver_sublocation")
                when "antagonist_sublocation" then location_by_slot.fetch("antagonist_sublocation")
                else
                  raise CommitError, "unknown placement=#{c['placement'].inspect}"
                end
          # Mechanical name from kingdom's culture (or default fallback).
          name = ::Harness::Naming.for(location: loc, rng: @rng)
          char = ::Harness::Character::Hatchery.spawn(
            llm_grunt:     @llm_grunt,
            name:          name,
            subrole:       c["subrole"],
            location_id:   loc.id,
            properties:    { "quest_slot" => c["slot"] },
            prose_context: prose_context_for(c),
            rng:           @rng
          )
          fresh_by_slot[c["slot"]] << char
        end

        # Second pass: resolve reused.
        reused_by_slot = Hash.new { |h, k| h[k] = [] }
        @hydrated[:reused_characters].each do |r|
          char = ::Character.find_by(id: r["existing_character_id"])
          raise CommitError, "reused_character id=#{r['existing_character_id']} not found" unless char
          reused_by_slot[r["slot"]] << char
        end

        # Build the slot-index map: per slot, fresh entries first, then reused.
        out = {}
        slot_ids = (fresh_by_slot.keys + reused_by_slot.keys).uniq
        slot_ids.each do |slot_id|
          combined = fresh_by_slot[slot_id] + reused_by_slot[slot_id]
          combined.each_with_index do |char, idx|
            out["#{slot_id}[#{idx}]"] = char
            out[slot_id] = char if idx.zero?  # bare slot name = index 0
          end
        end
        out
      end

      def prose_context_for(char_entry)
        "Spawned for quest \"#{@hydrated[:name]}\" (archetype=#{@archetype['id']}). " \
        "Slot=#{char_entry['slot']}. Subrole=#{char_entry['subrole']}. " \
        "Summary: #{@hydrated[:summary]}"
      end

      def create_items(location_by_slot)
        per_slot_counter = Hash.new(0)
        out = {}
        @hydrated[:items].each do |it|
          loc = location_by_slot.fetch(it["anchored_at"])
          item_name = synthesize_item_name(it)
          item = ::Item.create!(
            name:       item_name,
            subrole:    it["subrole"],
            location:   loc,
            properties: { "quest_slot" => it["slot"] }
          )
          idx = per_slot_counter[it["slot"]]
          per_slot_counter[it["slot"]] += 1
          out["#{it['slot']}[#{idx}]"] = item
          out[it["slot"]] = item if idx.zero?
        end
        out
      end

      # Items don't get LLM names either — synthesize a serviceable one from
      # subrole + a city/slot hint. The player will see the actual item in
      # narration; we just need something unique for the row.
      def synthesize_item_name(item_entry)
        slot_word = item_entry["slot"].to_s.tr("_", " ")
        subrole   = item_entry["subrole"]
        "#{@city.name} #{slot_word} (#{subrole})".strip
      end

      def commit_kickoff_event(location_by_slot, character_by_slot)
        kickoff_loc = location_by_slot.fetch("giver_sublocation")
        kickoff_gt  = @current_game_time - @hydrated[:kickoff_game_time_offset_minutes]

        participants = @hydrated[:kickoff_participant_slots].map { |slot_ref|
          char = character_by_slot[slot_ref] || character_by_slot[slot_ref.split("[").first]
          raise CommitError, "kickoff_participant_slot=#{slot_ref.inspect} did not resolve to a character" unless char
          { character: char, role: kickoff_role_for(char) }
        }

        # Safety net for FloorViolation: kickoff must be at or after every
        # participant's earliest narrative event. Hydrator's floor check
        # gates the obvious case (reused characters), but Hatchery-spawned
        # characters in THIS quest also have a fresh introduction event at
        # game_time = current_game_time (from propose_character behavior),
        # and we don't want that introduction-event to retroactively raise
        # the floor and block the kickoff. The clamp only acts when the
        # max existing narrative floor genuinely exceeds the kickoff.
        kickoff_gt = clamp_to_participant_floors(kickoff_gt, participants)

        ::Harness::Event::BackwardAppender.append(
          events: [ {
            game_time:    kickoff_gt,
            scope:        "local",
            location:     kickoff_loc,
            details: {
              "summary"   => @hydrated[:summary],
              "narrative" => @hydrated[:kickoff_narrative],
              "quest" => {
                "archetype_id" => @archetype["id"],
                "name"         => @hydrated[:name],
                "kickoff"      => true
              }
            },
            participants: participants
          } ],
          llm_client: @llm_grunt,
          logger:     @logger
        ).events.first
      end

      def kickoff_role_for(char)
        case char.properties && char.properties["quest_slot"]
        when "giver"      then "giver"
        when "antagonist" then "antagonist"
        else                   "supporter"
        end
      end

      # Safety net: walk every participant's existing narrative events,
      # find the max earliest-event game_time, and clamp the kickoff to
      # that floor + 1 if it would violate. BackwardAppender uses
      # Event.narrative scope (excludes introduction-events) for its floor
      # check, so we mirror that semantics here. Logs when the clamp fires
      # so the LLM-chosen offset can be tuned in playtest data.
      def clamp_to_participant_floors(kickoff_gt, participants)
        char_ids = participants.map { |p| p[:character].id }
        return kickoff_gt if char_ids.empty?

        floors = ::EventParticipant.joins(:event)
                                   .merge(::Event.narrative)
                                   .where(character_id: char_ids)
                                   .group(:character_id)
                                   .minimum("events.game_time")
        max_floor = floors.values.compact.max
        return kickoff_gt unless max_floor && kickoff_gt < max_floor

        adjusted = max_floor + 1
        @logger.warn { "[Quest::Committer] kickoff_gt=#{kickoff_gt} below participant max floor=#{max_floor}; clamping to #{adjusted}" }
        adjusted
      end

      def create_steps(quest:, character_by_slot_index:, item_by_slot_index:, location_by_slot:, kickoff_event:)
        @archetype["steps"].each_with_index do |step, i|
          desc = @hydrated[:steps][i]["description"]
          attrs = {
            quest:               quest,
            position:            i + 1,
            description:         desc,
            state:               "pending",
            fulfillment_kind:    step["kind"],
            related_event_ids:   [ kickoff_event.id ]
          }
          case step["kind"]
          when "information"
            char = resolve_character_slot(character_by_slot_index, step["target_slot"])
            attrs[:target_character_id] = char.id
          when "item_in_inventory"
            item = resolve_item_slot(item_by_slot_index, step["target_slot"])
            attrs[:target_item_id] = item.id
          when "character_dead"
            char = resolve_character_slot(character_by_slot_index, step["target_slot"])
            attrs[:target_character_id] = char.id
          when "character_at_location"
            char = resolve_character_slot(character_by_slot_index, step["target_slot"])
            # Convention: character_at_location targets the antagonist sublocation.
            loc = location_by_slot.fetch("antagonist_sublocation")
            attrs[:target_character_id] = char.id
            attrs[:target_location_id]  = loc.id
          end
          ::QuestStep.create!(attrs)
        end
      end

      def resolve_character_slot(map, slot_ref)
        normalized = slot_ref.include?("[") ? slot_ref : "#{slot_ref}[0]"
        map[normalized] || map[slot_ref.split("[").first] or
          raise CommitError, "couldn't resolve character slot=#{slot_ref.inspect}; known=#{map.keys.inspect}"
      end

      def resolve_item_slot(map, slot_ref)
        normalized = slot_ref.include?("[") ? slot_ref : "#{slot_ref}[0]"
        map[normalized] || map[slot_ref.split("[").first] or
          raise CommitError, "couldn't resolve item slot=#{slot_ref.inspect}; known=#{map.keys.inspect}"
      end
    end
  end
end
