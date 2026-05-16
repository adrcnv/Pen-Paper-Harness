require "json"
require "set"

module Harness
  module Quests
    # Parses + validates the authoring LLM's output for a quest. Produces a
    # structured payload the Committer can apply in one transaction. Failures
    # raise InvalidOutput so the Generator can retry with feedback.
    #
    # Post-Phase-2 schema:
    #   - characters[]: {slot, subrole, placement} — names are NOT supplied by
    #     the LLM; the committer assigns mechanically via Harness::Naming.
    #   - reused_characters[]: {slot, existing_character_id} — opt-in reuse of
    #     existing rows from local_cast. Each reuse consumes one slot fill.
    #   - kickoff_participant_slots: array of slot refs ("giver", "supporters[0]").
    #     References resolve to fresh OR reused characters; no name strings.
    #
    # Validation:
    # - Required top-level fields present and well-typed.
    # - Per-archetype-slot total = fresh.count + reused.count must equal
    #   slot.count.
    # - reused_characters references must exist in local_cast.
    # - No existing_character_id reused more than once.
    # - All kickoff_participant_slots resolve to a fill (fresh OR reused).
    # - steps.size == archetype.steps.size.
    # - Item anchored_at + character placement values are recognized.
    # - kickoff_game_time_offset_minutes in [1, current_game_time - 1].
    class Hydrator
      class InvalidOutput < StandardError
        attr_reader :errors
        def initialize(errors)
          @errors = Array(errors)
          super("invalid quest output:\n  - #{@errors.join("\n  - ")}")
        end
      end

      ALLOWED_PLACEMENTS = %w[giver_sublocation antagonist_sublocation city].freeze
      ALLOWED_ANCHORS    = %w[giver_sublocation antagonist_sublocation].freeze
      MIN_OFFSET_MINUTES = 1
      MAX_OFFSET_MINUTES = 10_000

      def self.hydrate(llm_output:, archetype:, current_game_time:, local_cast: [])
        new(llm_output, archetype, current_game_time, local_cast).hydrate
      end

      def initialize(llm_output, archetype, current_game_time, local_cast)
        @raw = if llm_output.is_a?(String)
          begin
            ::Harness::LLM::JsonResponse.parse(llm_output)
          rescue JSON::ParserError => e
            raise InvalidOutput, [ "output is not valid JSON: #{e.message}" ]
          end
        else
          llm_output
        end
        @archetype         = archetype
        @current_game_time = current_game_time
        @local_cast_ids    = local_cast.map { |c| c["id"] }.to_set
        # Per-id existence floors from local_cast — used to gate reuse so
        # the kickoff time satisfies BackwardAppender's FloorViolation rule.
        @local_cast_floors = local_cast.each_with_object({}) { |c, h|
          h[c["id"]] = c["earliest_event_game_time"]  # may be nil
        }
        @errors            = []
      end

      def hydrate
        unless @raw.is_a?(Hash)
          raise InvalidOutput, [ "top-level output must be a JSON object" ]
        end

        out = {}
        out[:name]                              = validate_string(:name)
        out[:summary]                            = validate_string(:summary)
        out[:kickoff_narrative]                  = validate_string(:kickoff_narrative)
        out[:kickoff_game_time_offset_minutes]   = validate_offset
        out[:characters]                         = validate_characters
        out[:reused_characters]                  = validate_reused_characters
        out[:locations]                          = validate_locations
        out[:items]                              = validate_items(out[:locations])
        out[:steps]                              = validate_steps

        # Slot count rule: for each character slot, (fresh + reused) == archetype count.
        validate_slot_totals(out[:characters], out[:reused_characters])

        # Resolve slot index map for kickoff participants: each entry in
        # kickoff_participant_slots must point at a fresh or reused fill.
        out[:kickoff_participant_slots] = validate_kickoff_slots(out[:characters], out[:reused_characters])

        # Floor constraint: every reused character's earliest event must be
        # at or before the proposed kickoff time. Catches the "LLM reused a
        # character whose first event is more recent than the picked kickoff"
        # failure that would otherwise crash at BackwardAppender's
        # FloorViolation, wasting the whole authoring pass.
        validate_reuse_floors(out[:reused_characters], out[:kickoff_game_time_offset_minutes])

        raise InvalidOutput, @errors if @errors.any?

        out
      end

      private

      def validate_string(key)
        v = @raw[key.to_s]
        unless v.is_a?(String) && !v.strip.empty?
          @errors << "#{key} must be a non-empty string"
          return nil
        end
        v.strip
      end

      def validate_offset
        v = @raw["kickoff_game_time_offset_minutes"]
        unless v.is_a?(Integer)
          @errors << "kickoff_game_time_offset_minutes must be an integer"
          return nil
        end
        if v < MIN_OFFSET_MINUTES
          @errors << "kickoff_game_time_offset_minutes=#{v} must be >= #{MIN_OFFSET_MINUTES}"
          return nil
        end
        if v > MAX_OFFSET_MINUTES
          @errors << "kickoff_game_time_offset_minutes=#{v} must be <= #{MAX_OFFSET_MINUTES}"
          return nil
        end
        if @current_game_time - v < 1
          @errors << "kickoff_game_time_offset_minutes=#{v} would place the kickoff before game start (current=#{@current_game_time})"
          return nil
        end
        v
      end

      def validate_characters
        arr = @raw["characters"]
        unless arr.is_a?(Array)
          @errors << "characters must be an array"
          return []
        end

        char_slots = @archetype["slots"].select { |s| s["kind"] == "character" }
        slot_ids   = char_slots.map { |s| s["id"] }.to_set

        out = []
        arr.each_with_index do |c, i|
          prefix = "characters[#{i}]"
          unless c.is_a?(Hash)
            @errors << "#{prefix} must be a Hash"
            next
          end
          slot      = c["slot"]
          subrole   = c["subrole"]
          placement = c["placement"]

          unless slot_ids.include?(slot)
            @errors << "#{prefix}.slot=#{slot.inspect} not a character slot in archetype"
            next
          end
          unless subrole.is_a?(String) && !subrole.strip.empty?
            @errors << "#{prefix}.subrole must be a non-empty string"
            next
          end
          unless ALLOWED_PLACEMENTS.include?(placement)
            @errors << "#{prefix}.placement=#{placement.inspect} must be one of #{ALLOWED_PLACEMENTS.inspect}"
            next
          end

          # Structural placement rule: giver MUST be at giver_sublocation,
          # antagonist MUST be at antagonist_sublocation (the engine depends
          # on this for sublocation creation + step resolution).
          case slot
          when "giver"
            @errors << "#{prefix}.placement must be \"giver_sublocation\" for giver slot" unless placement == "giver_sublocation"
          when "antagonist"
            @errors << "#{prefix}.placement must be \"antagonist_sublocation\" for antagonist slot" unless placement == "antagonist_sublocation"
          end

          out << { "slot" => slot, "subrole" => subrole.strip, "placement" => placement }
        end
        out
      end

      def validate_reused_characters
        arr = @raw["reused_characters"] || []
        unless arr.is_a?(Array)
          @errors << "reused_characters must be an array (or omitted)"
          return []
        end

        char_slots = @archetype["slots"].select { |s| s["kind"] == "character" }
        slot_ids   = char_slots.map { |s| s["id"] }.to_set

        seen_ids = ::Set.new
        out = []
        arr.each_with_index do |r, i|
          prefix = "reused_characters[#{i}]"
          unless r.is_a?(Hash)
            @errors << "#{prefix} must be a Hash"
            next
          end
          slot = r["slot"]
          id   = r["existing_character_id"]

          unless slot_ids.include?(slot)
            @errors << "#{prefix}.slot=#{slot.inspect} not a character slot in archetype"
            next
          end
          unless id.is_a?(Integer)
            @errors << "#{prefix}.existing_character_id must be an integer"
            next
          end
          unless @local_cast_ids.include?(id)
            @errors << "#{prefix}.existing_character_id=#{id} is not in local_cast — reuse only existing characters listed in the input"
            next
          end
          if seen_ids.include?(id)
            @errors << "#{prefix}.existing_character_id=#{id} reused more than once across this quest"
            next
          end
          seen_ids << id
          out << { "slot" => slot, "existing_character_id" => id }
        end
        out
      end

      def validate_slot_totals(characters, reused)
        char_slots = @archetype["slots"].select { |s| s["kind"] == "character" }
        slot_counts = char_slots.each_with_object({}) { |s, h| h[s["id"]] = s["count"] }

        fresh_seen  = Hash.new(0); characters.each { |c| fresh_seen[c["slot"]] += 1 }
        reused_seen = Hash.new(0); reused.each     { |r| reused_seen[r["slot"]] += 1 }

        slot_counts.each do |slot_id, want|
          got = fresh_seen[slot_id] + reused_seen[slot_id]
          if got != want
            @errors << "slot=#{slot_id} expects #{want} fills total, got fresh=#{fresh_seen[slot_id]} + reused=#{reused_seen[slot_id]} = #{got}"
          end
        end
      end

      def validate_kickoff_slots(characters, reused)
        arr = @raw["kickoff_participant_slots"]
        unless arr.is_a?(Array) && arr.any? && arr.all? { |s| s.is_a?(String) && !s.strip.empty? }
          @errors << "kickoff_participant_slots must be a non-empty array of slot reference strings"
          return []
        end

        # Build per-slot fill counts so we can validate slot[i] references.
        fills_per_slot = Hash.new(0)
        characters.each { |c| fills_per_slot[c["slot"]] += 1 }
        reused.each     { |r| fills_per_slot[r["slot"]] += 1 }

        out = []
        arr.each_with_index do |ref, i|
          ref = ref.strip
          slot_id, idx = parse_slot_ref(ref)
          if slot_id.nil?
            @errors << "kickoff_participant_slots[#{i}]=#{ref.inspect} is malformed (expected \"slot\" or \"slot[N]\")"
            next
          end
          unless fills_per_slot.key?(slot_id)
            @errors << "kickoff_participant_slots[#{i}]=#{ref.inspect} references slot=#{slot_id.inspect} that has no fills"
            next
          end
          if idx >= fills_per_slot[slot_id]
            @errors << "kickoff_participant_slots[#{i}]=#{ref.inspect} index #{idx} out of range; slot has #{fills_per_slot[slot_id]} fill(s)"
            next
          end
          out << ref
        end
        out
      end

      def parse_slot_ref(ref)
        m = ref.match(/\A([a-z_][a-z0-9_]*)(?:\[(\d+)\])?\z/i)
        return [ nil, nil ] unless m
        [ m[1], m[2] ? m[2].to_i : 0 ]
      end

      def validate_reuse_floors(reused, offset)
        return if reused.empty? || offset.nil?
        kickoff_gt = @current_game_time - offset
        violations = []
        reused.each do |r|
          id    = r["existing_character_id"]
          floor = @local_cast_floors[id]
          next if floor.nil?
          if kickoff_gt < floor
            violations << "reused id=#{id} (floor=#{floor})"
          end
        end
        return if violations.empty?
        max_floor = violations.map { |v| v[/floor=(\d+)/, 1].to_i }.max
        max_safe_offset = @current_game_time - max_floor
        @errors << "kickoff_game_time=#{kickoff_gt} (= current_game_time #{@current_game_time} - offset #{offset}) is before the earliest_event_game_time of these reused characters: #{violations.join(', ')}. Either pick an offset <= #{max_safe_offset} (so kickoff >= #{max_floor}), or drop those reused characters and spawn fresh instead."
      end

      def validate_locations
        arr = @raw["locations"]
        unless arr.is_a?(Array)
          @errors << "locations must be an array"
          return []
        end

        required = %w[giver_sublocation antagonist_sublocation]
        seen = {}
        out = []
        arr.each_with_index do |l, i|
          prefix = "locations[#{i}]"
          unless l.is_a?(Hash)
            @errors << "#{prefix} must be a Hash"
            next
          end
          slot = l["slot"]
          name = l["name"]
          desc = l["description"]
          unless required.include?(slot)
            @errors << "#{prefix}.slot=#{slot.inspect} must be one of #{required.inspect}"
            next
          end
          if !name.is_a?(String) || name.strip.empty?
            @errors << "#{prefix}.name must be a non-empty string"
            next
          end
          if !desc.is_a?(String) || desc.strip.empty?
            @errors << "#{prefix}.description must be a non-empty string"
            next
          end
          if seen.key?(slot)
            @errors << "#{prefix}.slot=#{slot.inspect} appears more than once"
            next
          end
          seen[slot] = true
          out << { "slot" => slot, "name" => name.strip, "description" => desc.strip }
        end

        missing = required - seen.keys
        missing.each { |m| @errors << "locations: missing entry for #{m.inspect}" }
        out
      end

      def validate_items(locations)
        arr = @raw["items"] || []
        unless arr.is_a?(Array)
          @errors << "items must be an array (or omitted)"
          return []
        end

        item_slot_counts = @archetype["slots"].select { |s| s["kind"] == "item" }
                                              .each_with_object({}) { |s, h| h[s["id"]] = s["count"] }

        location_slot_set = locations.map { |l| l["slot"] }.to_set

        per_slot_seen = Hash.new(0)
        out = []
        arr.each_with_index do |it, i|
          prefix = "items[#{i}]"
          unless it.is_a?(Hash)
            @errors << "#{prefix} must be a Hash"
            next
          end
          slot    = it["slot"]
          subrole = it["subrole"]
          anchor  = it["anchored_at"]
          @errors << "#{prefix}.slot=#{slot.inspect} not an item slot in archetype" unless item_slot_counts.key?(slot)
          if !subrole.is_a?(String) || subrole.strip.empty?
            @errors << "#{prefix}.subrole must be a non-empty string"
            next
          end
          unless ALLOWED_ANCHORS.include?(anchor) && location_slot_set.include?(anchor)
            @errors << "#{prefix}.anchored_at=#{anchor.inspect} must reference a declared location slot (#{ALLOWED_ANCHORS.inspect})"
            next
          end
          per_slot_seen[slot] += 1
          out << { "slot" => slot, "subrole" => subrole.strip, "anchored_at" => anchor }
        end

        item_slot_counts.each do |slot_id, want|
          got = per_slot_seen[slot_id] || 0
          @errors << "items: slot=#{slot_id} expects #{want}, got #{got}" if got != want
        end

        out
      end

      def validate_steps
        arr = @raw["steps"]
        unless arr.is_a?(Array)
          @errors << "steps must be an array"
          return []
        end
        expected = @archetype["steps"].size
        if arr.size != expected
          @errors << "steps must have #{expected} entries (one per archetype step); got #{arr.size}"
          return []
        end
        arr.each_with_index.map do |s, i|
          desc = s.is_a?(Hash) ? s["description"] : nil
          unless desc.is_a?(String) && !desc.strip.empty?
            @errors << "steps[#{i}].description must be a non-empty string"
            next nil
          end
          { "description" => desc.strip }
        end
      end
    end
  end
end
