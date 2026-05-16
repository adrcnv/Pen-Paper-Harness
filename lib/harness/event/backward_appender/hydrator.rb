require "json"

module Harness
  module Event
    class BackwardAppender
      class Hydrator
        class InvalidOutput < StandardError
          attr_reader :errors
          def initialize(errors)
            @errors = Array(errors)
            super("invalid backward-append validator output:\n  - #{@errors.join("\n  - ")}")
          end
        end

        def self.hydrate(llm_output:)
          new(llm_output).hydrate
        end

        def initialize(llm_output)
          @llm = if llm_output.is_a?(String)
            begin
              Harness::LLM::JsonResponse.parse(llm_output)
            rescue JSON::ParserError => e
              raise InvalidOutput, [ "output is not valid JSON: #{e.message}" ]
            end
          else
            llm_output
          end
          @errors = []
        end

        def hydrate
          validate_top_level
          raise_if_errors

          consistent = @llm["consistent"]
          reasons    = validate_reasons(consistent)
          raise_if_errors

          { "consistent" => consistent, "reasons" => reasons }
        end

        private

        def validate_top_level
          unless @llm.is_a?(Hash)
            @errors << "top-level output must be a JSON object"
            return
          end
          unless [ true, false ].include?(@llm["consistent"])
            @errors << "\"consistent\" must be a boolean (true/false)"
          end
          unless @llm["reasons"].is_a?(Array)
            @errors << "\"reasons\" must be an array (empty if consistent: true)"
          end
        end

        def validate_reasons(consistent)
          entries = Array(@llm["reasons"])

          if consistent && entries.any?
            @errors << "consistent=true requires reasons to be empty (got #{entries.size} entries)"
            return []
          end
          if consistent == false && entries.empty?
            @errors << "consistent=false requires at least one reason"
            return []
          end

          out = []
          entries.each_with_index do |r, i|
            unless r.is_a?(String) && !r.strip.empty?
              @errors << "reasons[#{i}] must be a non-empty string"
              next
            end
            out << r.strip
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
