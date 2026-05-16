module Harness
  module Travel
    # Single small-model LLM call: given encounter bucket + biome + anchor +
    # existing-names blocklist, produce { name, description } for the
    # wilderness_leaf the encounter will spawn.
    #
    # Cache prefix-stable: system is the static preamble; user holds all the
    # per-call data. Repair-retry feedback goes in user only — system stays
    # byte-identical so adapter caching keeps hitting.
    class EncounterPlace
      PREAMBLE_PATH = Rails.root.join("lib/harness/prompts/encounter_place.txt")

      Result = Struct.new(:name, :description, keyword_init: true)

      class InvalidOutput < StandardError
        attr_reader :errors
        def initialize(errors)
          @errors = Array(errors)
          super("invalid encounter-place output:\n  - #{@errors.join("\n  - ")}")
        end
      end

      MIN_WORDS  = 3
      MIN_DESC   = 30
      MAX_DESC   = 300

      attr_reader :logger

      def initialize(llm_client:, logger: Rails.logger, max_retries: 2)
        @llm         = llm_client
        @logger      = logger
        @max_retries = max_retries
      end

      def generate(bucket:, biome:, anchor_name:, existing_names: nil)
        existing_names ||= ::Location.pluck(:name)

        attempts = 0
        system   = preamble
        user     = build_user(bucket: bucket, biome: biome, anchor_name: anchor_name, existing_names: existing_names)

        loop do
          attempts += 1
          logger.debug { "[Travel::EncounterPlace] LLM call attempt #{attempts}" }

          raw = ::Harness::CostTracker.in_subsystem(:travel_encounter_place) {
            @llm.complete(system: system, user: user)
          }
          logger.debug { "[Travel::EncounterPlace] raw output (attempt #{attempts}, #{raw.size} bytes):\n#{raw}" }

          begin
            return validate(raw, existing_names)
          rescue InvalidOutput => e
            logger.warn { "[Travel::EncounterPlace] validation failed (attempt #{attempts}/#{@max_retries + 1}): #{e.errors.join('; ')}" }
            raise if attempts > @max_retries

            user = repair_user(user, raw, e.errors)
          end
        end
      end

      private

      def preamble
        @preamble ||= File.read(PREAMBLE_PATH)
      end

      def build_user(bucket:, biome:, anchor_name:, existing_names:)
        payload = {
          "bucket"         => bucket,
          "biome"          => biome,
          "anchor_name"    => anchor_name,
          "existing_names" => existing_names
        }
        "INPUT:\n#{JSON.pretty_generate(payload)}"
      end

      def validate(raw, existing_names)
        parsed =
          begin
            ::Harness::LLM::JsonResponse.parse(raw)
          rescue JSON::ParserError => e
            raise InvalidOutput, [ "output is not valid JSON: #{e.message}" ]
          end

        errors = []
        errors << "top-level output must be a JSON object" unless parsed.is_a?(Hash)
        if parsed.is_a?(Hash)
          errors.concat(check_name(parsed["name"], existing_names))
          errors.concat(check_description(parsed["description"]))
        end

        raise InvalidOutput, errors if errors.any?

        Result.new(name: parsed["name"].strip, description: parsed["description"].strip)
      end

      def check_name(name, existing_names)
        out = []
        unless name.is_a?(String)
          out << "\"name\" must be a string"
          return out
        end
        stripped = name.strip
        out << "\"name\" must be non-empty" if stripped.empty?
        words = stripped.split(/\s+/)
        out << "\"name\" must be at least #{MIN_WORDS} words (got #{words.length}: #{stripped.inspect})" if words.length < MIN_WORDS
        if existing_names.any? { |n| n.casecmp(stripped) == 0 }
          out << "\"name\" #{stripped.inspect} collides with an existing Location — pick a different name"
        end
        out
      end

      def check_description(desc)
        out = []
        unless desc.is_a?(String)
          out << "\"description\" must be a string"
          return out
        end
        stripped = desc.strip
        out << "\"description\" is too short (<#{MIN_DESC} chars)" if stripped.length < MIN_DESC
        out << "\"description\" is too long (>#{MAX_DESC} chars)" if stripped.length > MAX_DESC
        out
      end

      def repair_user(original_user, bad_output, errors)
        <<~REPAIR
          #{original_user}

          YOUR PREVIOUS OUTPUT WAS REJECTED. Here is what you produced:
          #{bad_output}

          ERRORS:
          #{errors.map { |e| "- #{e}" }.join("\n")}

          Fix ALL errors and output the corrected JSON. Follow the HARD RULES exactly.
        REPAIR
      end
    end
  end
end
