require "json"

module Harness
  module Stats
    class Hydrator
      class InvalidOutput < StandardError
        attr_reader :errors
        def initialize(errors)
          @errors = Array(errors)
          super("invalid stats output:\n  - #{@errors.join("\n  - ")}")
        end
      end

      STAT_RANGE = (3..18).freeze
      MIN_LEVEL  = 1
      # No upper level cap — a retired archmage tending bar can be level 14.
      # Validate sanity at a soft ceiling well above any reasonable game ceiling
      # to catch obvious LLM hallucination (level 9999) without rejecting
      # legitimate outliers.
      LEVEL_SANITY_CEILING = 100
      VALID_CLASSES = %w[commoner fighter mage sorcerer cleric rogue ranger].freeze

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

        validate_level
        validate_class
        validate_each_stat
        raise_if_errors

        build_output
      end

      private

      def validate_top_level
        unless @llm.is_a?(Hash)
          @errors << "top-level output must be a JSON object"
        end
      end

      def validate_level
        v = @llm["level"]
        if v.nil?
          @errors << "missing field: level"
        elsif !v.is_a?(Integer)
          @errors << "level must be integer (got #{v.inspect})"
        elsif v < MIN_LEVEL
          @errors << "level=#{v} must be >= #{MIN_LEVEL}"
        elsif v > LEVEL_SANITY_CEILING
          @errors << "level=#{v} exceeds sanity ceiling #{LEVEL_SANITY_CEILING} (likely hallucination)"
        end
      end

      def validate_class
        v = @llm["character_class"]
        if v.nil?
          @errors << "missing field: character_class"
        elsif !v.is_a?(String)
          @errors << "character_class must be a string (got #{v.inspect})"
        elsif !VALID_CLASSES.include?(v)
          @errors << "character_class=#{v.inspect} must be one of #{VALID_CLASSES.inspect}"
        end
      end

      def validate_each_stat
        ::Character::STATS.each do |stat|
          v = @llm[stat]
          if v.nil?
            @errors << "missing stat: #{stat}"
          elsif !v.is_a?(Integer)
            @errors << "#{stat} must be integer (got #{v.inspect})"
          elsif !STAT_RANGE.cover?(v)
            @errors << "#{stat}=#{v} out of range [#{STAT_RANGE.min}, #{STAT_RANGE.max}]"
          end
        end
      end

      def build_output
        out = ::Character::STATS.each_with_object({}) do |stat, h|
          h[stat.to_sym] = @llm[stat].to_i
        end
        out[:level]           = @llm["level"].to_i
        out[:character_class] = @llm["character_class"].to_s
        out
      end

      def raise_if_errors
        raise InvalidOutput, @errors if @errors.any?
      end
    end
  end
end
