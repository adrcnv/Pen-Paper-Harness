require "json"
require "set"

module Harness
  module Genesis
    # Hydrator for Genesis output (post-Phase-3).
    #
    # The LLM no longer picks character names. It declares a `characters`
    # array of `{id, subrole}` entries — each id is a cluster-local slug
    # ("founder", "scholar") that ties the same actor across multiple events.
    # The engine assigns a mechanical name per id when Hatcherying the row.
    #
    # Validates:
    # - top-level shape (characters, events, pending_appearances)
    # - characters: array of {id, subrole}; ids unique snake_case slugs
    # - events: each participant's actor_id resolves to a characters[] entry
    # - pending_appearances: actor_id resolves to a characters[] entry
    class Hydrator
      class InvalidOutput < StandardError
        attr_reader :errors
        def initialize(errors)
          @errors = Array(errors)
          super("invalid genesis output:\n  - #{@errors.join("\n  - ")}")
        end
      end

      ALLOWED_SCOPES                = %w[local regional].freeze
      MAX_EVENTS                    = 8
      MAX_PENDING_APPEARANCES       = 1
      MAX_CHARACTERS                = 5
      PA_INTENT_MIN_LEN             = 20
      PA_INTENT_MAX_LEN             = 250
      ACTOR_ID_PATTERN              = /\A[a-z][a-z0-9_]*\z/

      # Hydrated output: characters array + events array + pending_appearances array.
      # The committer/generator translates `characters` into Hatchery spawns,
      # then resolves each event participant's actor_id to the spawned row.
      Result = Struct.new(:characters, :events, :pending_appearances, keyword_init: true)

      def self.hydrate(llm_output:, current_game_time:)
        new(llm_output, current_game_time).hydrate
      end

      def initialize(llm_output, current_game_time)
        @llm = if llm_output.is_a?(String)
          begin
            Harness::LLM::JsonResponse.parse(llm_output)
          rescue JSON::ParserError => e
            raise InvalidOutput, [ "output is not valid JSON: #{e.message}" ]
          end
        else
          llm_output
        end
        @current_game_time = current_game_time
        @errors            = []
      end

      def hydrate
        validate_top_level
        raise_if_errors

        characters = validate_characters
        raise_if_errors

        actor_id_set = characters.map { |c| c["id"] }.to_set

        events = validate_events(actor_id_set)
        raise_if_errors

        pending = validate_pending_appearances(actor_id_set)
        raise_if_errors

        Result.new(characters: characters, events: events, pending_appearances: pending)
      end

      private

      def validate_top_level
        unless @llm.is_a?(Hash)
          @errors << "top-level output must be a JSON object"
          return
        end
        unless @llm["events"].is_a?(Array)
          @errors << "\"events\" must be an array (empty is allowed)"
        end
        # `characters` is allowed to be missing when `events` is empty
        # (a no-history place needs no character rows). Otherwise it must
        # be present and cover every actor_id referenced.
        if @llm["characters"] && !@llm["characters"].is_a?(Array)
          @errors << "\"characters\" must be an array if present"
        end
      end

      def validate_characters
        raw = Array(@llm["characters"])
        if raw.size > MAX_CHARACTERS
          @errors << "characters.size=#{raw.size} exceeds MAX_CHARACTERS=#{MAX_CHARACTERS}"
          return []
        end

        seen_ids = ::Set.new
        out = []
        raw.each_with_index do |c, i|
          prefix = "characters[#{i}]"
          unless c.is_a?(Hash)
            @errors << "#{prefix} is not an object"
            next
          end
          id      = c["id"]
          subrole = c["subrole"]
          unless id.is_a?(String) && id.match?(ACTOR_ID_PATTERN)
            @errors << "#{prefix}.id must be a snake_case slug matching #{ACTOR_ID_PATTERN.inspect}"
            next
          end
          if seen_ids.include?(id)
            @errors << "#{prefix}.id=#{id.inspect} appears more than once"
            next
          end
          seen_ids << id
          unless subrole.is_a?(String) && !subrole.strip.empty?
            @errors << "#{prefix}.subrole must be a non-empty string"
            next
          end
          out << { "id" => id, "subrole" => subrole.strip }
        end
        out
      end

      def validate_events(actor_id_set)
        out = []
        events = Array(@llm["events"])
        if events.size > MAX_EVENTS
          @errors << "events.size=#{events.size} exceeds MAX_EVENTS=#{MAX_EVENTS}"
          return out
        end

        events.each_with_index do |e, i|
          prefix = "events[#{i}]"
          unless e.is_a?(Hash)
            @errors << "#{prefix} is not an object"
            next
          end

          gt = e["game_time"]
          unless gt.is_a?(Integer)
            @errors << "#{prefix}: game_time must be an integer"
            next
          end
          if gt >= @current_game_time
            @errors << "#{prefix}: game_time=#{gt} must be strictly less than current_game_time=#{@current_game_time}"
            next
          end

          scope = e["scope"]
          unless ALLOWED_SCOPES.include?(scope)
            @errors << "#{prefix}: scope=#{scope.inspect} must be one of #{ALLOWED_SCOPES.inspect}"
            next
          end

          details = e["details"]
          unless details.is_a?(Hash)
            @errors << "#{prefix}: details must be an object"
            next
          end

          participants = validate_participants(e["participants"], prefix, actor_id_set)
          next if participants.nil?

          out << {
            "game_time"    => gt,
            "scope"        => scope,
            "details"      => details,
            "participants" => participants
          }
        end
        out
      end

      def validate_participants(raw, prefix, actor_id_set)
        list = Array(raw)
        out  = []
        list.each_with_index do |p, j|
          sub = "#{prefix}.participants[#{j}]"
          unless p.is_a?(Hash)
            @errors << "#{sub} is not an object"
            return nil
          end
          aid  = p["actor_id"]
          role = p["role"]
          if p["actor_name"]
            @errors << "#{sub}: \"actor_name\" is retired; use \"actor_id\" matching a characters[].id"
            return nil
          end
          unless aid.is_a?(String) && !aid.strip.empty?
            @errors << "#{sub}: actor_id must be a non-empty string"
            return nil
          end
          unless role.is_a?(String) && !role.strip.empty?
            @errors << "#{sub}: role must be a non-empty string"
            return nil
          end
          stripped = aid.strip
          unless actor_id_set.include?(stripped)
            @errors << "#{sub}: actor_id=#{stripped.inspect} not declared in characters[]"
            return nil
          end
          out << { "actor_id" => stripped, "role" => role.strip }
        end
        out
      end

      def validate_pending_appearances(actor_id_set)
        raw = @llm["pending_appearances"]
        return [] if raw.nil?
        unless raw.is_a?(Array)
          @errors << "\"pending_appearances\" must be an array (or omitted)"
          return []
        end
        if raw.size > MAX_PENDING_APPEARANCES
          @errors << "pending_appearances.size=#{raw.size} exceeds MAX_PENDING_APPEARANCES=#{MAX_PENDING_APPEARANCES}"
          return []
        end

        out = []
        raw.each_with_index do |entry, i|
          prefix = "pending_appearances[#{i}]"
          unless entry.is_a?(Hash)
            @errors << "#{prefix} is not an object"
            next
          end

          if entry["actor_name"]
            @errors << "#{prefix}: \"actor_name\" is retired; use \"actor_id\" matching a characters[].id"
            next
          end

          aid = entry["actor_id"]
          unless aid.is_a?(String) && !aid.strip.empty?
            @errors << "#{prefix}: actor_id must be a non-empty string"
            next
          end
          aid = aid.strip
          unless actor_id_set.include?(aid)
            @errors << "#{prefix}: actor_id=#{aid.inspect} not declared in characters[]"
            next
          end

          intent = entry["intent_text"]
          unless intent.is_a?(String)
            @errors << "#{prefix}: intent_text must be a string"
            next
          end
          intent = intent.strip
          if intent.length < PA_INTENT_MIN_LEN || intent.length > PA_INTENT_MAX_LEN
            @errors << "#{prefix}: intent_text length=#{intent.length} must be between #{PA_INTENT_MIN_LEN} and #{PA_INTENT_MAX_LEN}"
            next
          end

          out << { "actor_id" => aid, "intent_text" => intent }
        end
        out
      end

      def raise_if_errors
        raise InvalidOutput, @errors if @errors.any?
      end
    end
  end
end
