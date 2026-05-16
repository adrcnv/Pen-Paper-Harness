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
        AGENDA_MIN_LEN   = 20
        AGENDA_MAX_LEN   = 250

        Agenda = Struct.new(:character_name, :text, keyword_init: true)

        Result = Struct.new(:internal_states, :agenda, :extras, keyword_init: true)

        # Returns Result(internal_states: {name => prose}, agenda: Agenda|nil, extras: [str, ...]).
        # The orchestrator maps names back to character_ids when committing
        # to the Active scene. Extras are scene-bound, RAM-only ambient
        # nameless figures (the "an old fisherman nursing a beer" line).
        # Agenda is rare — at most one per scene, often nil.
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

          states = validate_states
          agenda = validate_agenda
          extras = validate_extras
          raise_if_errors

          Result.new(internal_states: states, agenda: agenda, extras: extras)
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
          # agenda is OPTIONAL (and most scenes should omit it). When present
          # it must be an object with character_name + text. Arrays / strings /
          # other shapes are flagged so the LLM can repair.
          if @llm.key?("agenda") && !@llm["agenda"].nil? && !@llm["agenda"].is_a?(Hash)
            @errors << "\"agenda\" must be an object {character_name:, text:} when present"
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

        # Returns nil when the field is absent (the common case) or fully
        # validated Agenda. Per the prompt, at most one agenda total, scoped
        # to a single named character. Unknown character_name → reject so
        # the LLM repairs rather than silently dropping.
        def validate_agenda
          raw = @llm["agenda"]
          return nil if raw.nil?
          return nil unless raw.is_a?(Hash)  # top-level shape error already flagged

          name = raw["character_name"]
          text = raw["text"]

          unless name.is_a?(String)
            @errors << "agenda.character_name must be a string"
            return nil
          end
          unless @expected.include?(name)
            @errors << "agenda.character_name #{name.inspect} is not in INPUT.characters (expected one of: #{@expected.to_a.join(', ')})"
            return nil
          end
          unless text.is_a?(String)
            @errors << "agenda.text must be a string"
            return nil
          end
          stripped = text.strip
          if stripped.length < AGENDA_MIN_LEN
            @errors << "agenda.text is too short (<#{AGENDA_MIN_LEN} chars)"
            return nil
          end
          if stripped.length > AGENDA_MAX_LEN
            @errors << "agenda.text is too long (>#{AGENDA_MAX_LEN} chars)"
            return nil
          end

          Agenda.new(character_name: name, text: stripped)
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
