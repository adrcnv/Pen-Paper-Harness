require "json"
require "set"

module Harness
  module Scene
    class InternalState
      class Hydrator
        class InvalidOutput < StandardError
          attr_reader :errors
          def initialize(errors)
            @errors = Array(errors)
            super("invalid scene internal-state output:\n  - #{@errors.join("\n  - ")}")
          end
        end

        MIN_LEN          = 10
        MAX_LEN          = 400
        EXTRA_MIN_LEN    = 10
        EXTRA_MAX_LEN    = 200
        # Raised to support the populated-place-with-no-named-characters case
        # (e.g., a city's market with no character rows yet — the LLM emits
        # 2-4 ambient figures so narration has scene flavor to render).
        MAX_EXTRAS       = 4
        AGENDA_MAX_LEN   = 250

        Result = Struct.new(:internal_states, :agendas, :extras, keyword_init: true)

        # Returns Result(internal_states: {name => prose}, agendas: {name => text}, extras: [str, ...]).
        # The orchestrator maps names back to character_ids when committing
        # to the Active scene. Extras are scene-bound, RAM-only ambient
        # nameless figures (the "an old fisherman nursing a beer" line).
        # agendas is per-present-character (their angle toward the player this
        # scene); some characters have none (omitted). The initiative consumer
        # reads these to decide who, if anyone, acts on a given turn.
        def self.hydrate(llm_output:, expected_names:)
          new(llm_output, expected_names).hydrate
        end

        def initialize(llm_output, expected_names)
          @llm = if llm_output.is_a?(String)
            begin
              Harness::LLM::JsonResponse.parse(llm_output)
            rescue JSON::ParserError => e
              raise InvalidOutput, [ "output is not valid JSON: #{e.message}" ]
            end
          else
            llm_output
          end
          @expected = Set.new(expected_names)
          @errors   = []
        end

        def hydrate
          validate_top_level
          raise_if_errors

          states  = validate_states
          agendas = validate_agendas
          extras  = validate_extras
          raise_if_errors

          Result.new(internal_states: states, agendas: agendas, extras: extras)
        end

        private

        def validate_top_level
          unless @llm.is_a?(Hash)
            @errors << "top-level output must be a JSON object"
            return
          end
          unless @llm["internal_states"].is_a?(Hash)
            @errors << "\"internal_states\" must be an object keyed by character name"
          end
          # extras is OPTIONAL — older models or edge cases may omit it.
          # We treat omission as [], not as an error, to keep cache prefix
          # stable and avoid breaking callers who don't care.
          if @llm.key?("extras") && !@llm["extras"].is_a?(Array)
            @errors << "\"extras\" must be an array of strings"
          end
          # agendas is OPTIONAL — a map {character_name => angle}. Per-character;
          # some/all may be omitted. Must be an object when present.
          if @llm.key?("agendas") && !@llm["agendas"].nil? && !@llm["agendas"].is_a?(Hash)
            @errors << "\"agendas\" must be an object keyed by character name when present"
          end
        end

        def validate_states
          out = {}
          states = @llm["internal_states"] || {}

          missing    = @expected - states.keys
          unexpected = states.keys.to_set - @expected
          if missing.any?
            @errors << "missing entries for character(s): #{missing.to_a.join(', ')}"
          end
          if unexpected.any?
            @errors << "unexpected entries for character(s): #{unexpected.to_a.join(', ')} (not in INPUT.characters)"
          end

          states.each do |name, prose|
            unless @expected.include?(name)
              next  # already flagged above
            end
            unless prose.is_a?(String)
              @errors << "internal_states[#{name.inspect}] must be a string"
              next
            end
            stripped = prose.strip
            if stripped.empty?
              @errors << "internal_states[#{name.inspect}] must be a non-empty string"
              next
            end
            if stripped.length < MIN_LEN
              @errors << "internal_states[#{name.inspect}] is too short (<#{MIN_LEN} chars)"
              next
            end
            if stripped.length > MAX_LEN
              @errors << "internal_states[#{name.inspect}] is too long (>#{MAX_LEN} chars)"
              next
            end
            out[name] = stripped
          end
          out
        end

        # Returns {name => angle} for present characters that have a seeded
        # agenda this scene. Per-character and optional — an empty/omitted entry
        # just means that character has no particular angle (drop silently).
        # Unknown names are flagged so the LLM repairs rather than mis-keying.
        def validate_agendas
          raw = @llm["agendas"]
          return {} if raw.nil?
          return {} unless raw.is_a?(Hash)  # top-level shape error already flagged

          out = {}
          raw.each do |name, text|
            unless @expected.include?(name)
              @errors << "agendas key #{name.inspect} is not in INPUT.characters (expected one of: #{@expected.to_a.join(', ')})"
              next
            end
            unless text.is_a?(String)
              @errors << "agendas[#{name.inspect}] must be a string"
              next
            end
            stripped = text.strip
            next if stripped.empty?  # no angle for this character — fine
            if stripped.length > AGENDA_MAX_LEN
              @errors << "agendas[#{name.inspect}] is too long (>#{AGENDA_MAX_LEN} chars)"
              next
            end
            out[name] = stripped
          end
          out
        end

        def validate_extras
          raw = @llm["extras"]
          return [] unless raw.is_a?(Array)

          # Cap silently rather than erroring — model produced too many,
          # we just take the first N. Soft trim, no retry needed.
          trimmed = raw.first(MAX_EXTRAS)

          out = []
          trimmed.each_with_index do |item, i|
            unless item.is_a?(String)
              @errors << "extras[#{i}] must be a string"
              next
            end
            stripped = item.strip
            if stripped.empty?
              @errors << "extras[#{i}] must be a non-empty string"
              next
            end
            if stripped.length < EXTRA_MIN_LEN
              @errors << "extras[#{i}] is too short (<#{EXTRA_MIN_LEN} chars)"
              next
            end
            if stripped.length > EXTRA_MAX_LEN
              @errors << "extras[#{i}] is too long (>#{EXTRA_MAX_LEN} chars)"
              next
            end
            out << stripped
          end
          out
        end

        def raise_if_errors
          raise InvalidOutput, @errors if @errors.any?
        end
      end
    end
  end
end
