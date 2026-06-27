require "json"

module Harness
  module Description
    class Hydrator
      class InvalidOutput < StandardError
        attr_reader :errors
        def initialize(errors)
          @errors = Array(errors)
          super("invalid description output:\n  - #{@errors.join("\n  - ")}")
        end
      end

      MIN_LEN = 30
      MAX_LEN = 400

      # Per-field length bounds. personality is a compact trait list now
      # (not prose), so it gets a shorter floor + ceiling; appearance stays
      # prose. Falls back to MIN_LEN/MAX_LEN for any unlisted field.
      FIELD_BOUNDS = {
        "personality" => [ 10, 120 ],
        "appearance"  => [ 30, 400 ]
      }.freeze

      def self.hydrate(llm_output:)
        new(llm_output).hydrate
      end

      def initialize(llm_output)
        @llm = if llm_output.is_a?(String)
          Harness::LLM::JsonResponse.parse(llm_output)
        else
          llm_output
        end
        @errors = []
      rescue JSON::ParserError => e
        raise InvalidOutput, [ "output is not valid JSON: #{e.message.lines.first.strip}" ]
      end

      def hydrate
        validate_top_level
        raise_if_errors

        validate_field("personality")
        validate_field("appearance")
        raise_if_errors

        {
          personality: @llm["personality"].strip,
          appearance:  @llm["appearance"].strip
        }
      end

      private

      def validate_top_level
        unless @llm.is_a?(Hash)
          @errors << "top-level output must be a JSON object"
        end
      end

      def validate_field(name)
        v = @llm[name]
        if v.nil?
          @errors << "missing field: #{name}"
        elsif !v.is_a?(String)
          @errors << "#{name} must be a string"
        else
          stripped = v.strip
          min, max = FIELD_BOUNDS.fetch(name, [ MIN_LEN, MAX_LEN ])
          if stripped.length < min || stripped.length > max
            @errors << "#{name} length=#{stripped.length} must be between #{min} and #{max}"
          end
        end
      end

      def raise_if_errors
        raise InvalidOutput, @errors if @errors.any?
      end
    end
  end
end
