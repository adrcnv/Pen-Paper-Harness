require "set"

module Harness
  module Worldgen
    module Naming
      class Hydrator
        class InvalidOutput < StandardError
          attr_reader :errors
          def initialize(errors)
            @errors = Array(errors)
            super("invalid worldgen naming output:\n  - #{@errors.join("\n  - ")}")
          end
        end

        NAME_MIN = 2
        NAME_MAX = 60
        DESC_MIN = 20
        DESC_MAX = 400

        # Returns { kingdom: {name, description}, cities: { id => {name, description} } }
        def self.hydrate(llm_output:, member_ids:)
          new(llm_output, member_ids).hydrate
        end

        def initialize(llm_output, member_ids)
          @llm = if llm_output.is_a?(String)
            begin
              Harness::LLM::JsonResponse.parse(llm_output)
            rescue JSON::ParserError => e
              raise InvalidOutput, [ "output is not valid JSON: #{e.message}" ]
            end
          else
            llm_output
          end
          @expected_ids = Set.new(member_ids)
          @errors       = []
        end

        def hydrate
          validate_top_level
          raise_if_errors

          out = {
            kingdom: validate_kingdom,
            cities:  validate_cities
          }
          raise_if_errors

          out
        end

        private

        def validate_top_level
          unless @llm.is_a?(Hash)
            @errors << "top-level output must be a JSON object"
            return
          end
          unless @llm["kingdom"].is_a?(Hash)
            @errors << "\"kingdom\" must be an object with name and description"
          end
          unless @llm["cities"].is_a?(Hash)
            @errors << "\"cities\" must be an object keyed by city id"
          end
        end

        def validate_kingdom
          k = @llm["kingdom"] || {}
          name        = string_field(k, "kingdom.name", NAME_MIN, NAME_MAX)
          description = string_field(k, "kingdom.description", DESC_MIN, DESC_MAX)
          { name: name, description: description }
        end

        def validate_cities
          cities_in = @llm["cities"] || {}
          got_ids   = cities_in.keys.map { |k| Integer(k.to_s) rescue nil }.compact.to_set

          missing = @expected_ids - got_ids
          extras  = got_ids - @expected_ids
          @errors << "missing entries for city ids: #{missing.to_a.sort.join(', ')}" if missing.any?
          @errors << "unexpected entries for city ids: #{extras.to_a.sort.join(', ')}"  if extras.any?

          out = {}
          cities_in.each do |key, val|
            id = Integer(key.to_s) rescue nil
            next unless id && @expected_ids.include?(id)
            unless val.is_a?(Hash)
              @errors << "cities[#{id}] must be an object with name and description"
              next
            end
            out[id] = {
              name:        string_field(val, "cities[#{id}].name", NAME_MIN, NAME_MAX),
              description: string_field(val, "cities[#{id}].description", DESC_MIN, DESC_MAX)
            }
          end
          out
        end

        def string_field(hash, label, min_len, max_len)
          v = hash[label.split(".").last] || hash[label.split("[").last.tr("]", "").split(".").last]
          # Direct key access — labels like "kingdom.name" pass key "name".
          # We re-extract here using just the leaf.
          leaf = label.split(/[.\[\]]/).reject(&:empty?).last
          v = hash[leaf]
          unless v.is_a?(String)
            @errors << "#{label} must be a string"
            return nil
          end
          stripped = v.strip
          if stripped.length < min_len
            @errors << "#{label} too short (<#{min_len} chars): #{stripped.inspect}"
            return nil
          end
          if stripped.length > max_len
            @errors << "#{label} too long (>#{max_len} chars)"
            return nil
          end
          stripped
        end

        def raise_if_errors
          raise InvalidOutput, @errors if @errors.any?
        end
      end
    end
  end
end
