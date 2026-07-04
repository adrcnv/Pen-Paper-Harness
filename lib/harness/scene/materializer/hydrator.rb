require "json"

module Harness
  module Scene
    class Materializer
      class Hydrator
        class InvalidOutput < StandardError
          attr_reader :errors
          def initialize(errors)
            @errors = Array(errors)
            super("invalid scene materializer output:\n  - #{@errors.join("\n  - ")}")
          end
        end

        def self.hydrate(llm_output:, candidate_ids:, present_names:, slots_to_fill:)
          new(llm_output, candidate_ids, present_names, slots_to_fill).hydrate
        end

        def initialize(llm_output, candidate_ids, present_names, slots_to_fill)
          @llm           = llm_output.is_a?(String) ? Harness::LLM::JsonResponse.parse(llm_output) : llm_output
          @candidate_set = Set.new(candidate_ids)
          @present_set   = Set.new(present_names)
          @slots_to_fill = slots_to_fill
          @errors        = []
        end

        def hydrate
          validate_top_level
          raise_if_errors

          validate_entries
          raise_if_errors

          validate_budget
          raise_if_errors

          build_output
        end

        private

        def validate_top_level
          unless @llm.is_a?(Hash)
            @errors << "top-level output must be a JSON object"
            return
          end
          unless @llm["reuse"].is_a?(Array)
            @errors << '"reuse" must be an array (may be empty)'
          end
          unless @llm["spawn"].is_a?(Array)
            @errors << '"spawn" must be an array (may be empty)'
          end
        end

        def validate_entries
          validate_reuse_entries
          validate_spawn_entries
        end

        def validate_reuse_entries
          seen_ids = Set.new
          Array(@llm["reuse"]).each_with_index do |e, i|
            prefix = "reuse[#{i}]"
            unless e.is_a?(Hash)
              @errors << "#{prefix} is not an object"
              next
            end

            cid = e["character_id"]
            if !cid.is_a?(Integer)
              @errors << "#{prefix}: character_id must be an integer"
            elsif !@candidate_set.include?(cid)
              @errors << "#{prefix}: character_id=#{cid} is not in CANDIDATES"
            elsif seen_ids.include?(cid)
              @errors << "#{prefix}: character_id=#{cid} appears twice in reuse"
            else
              seen_ids << cid
            end

            validate_subrole(e, prefix)
            validate_properties(e, prefix)
          end
        end

        def validate_spawn_entries
          # Post-Phase-3: names are mechanical. `name` field is silently
          # dropped from spawn entries; only subrole + properties matter for
          # the LLM. The committer (Materializer#apply) assigns names via
          # Harness::Naming.unique_for at the spawn location.
          Array(@llm["spawn"]).each_with_index do |e, i|
            prefix = "spawn[#{i}]"
            unless e.is_a?(Hash)
              @errors << "#{prefix} is not an object"
              next
            end
            validate_subrole(e, prefix)
            validate_properties(e, prefix)
          end
        end

        # `subrole` here is the character's trade as a CANONICAL bucket — it
        # MUST be an exact member of the closed Vocations vocabulary. This is
        # what keeps materialized townsfolk out of free-text sentence-drift
        # ("wealthy merchant with flour debts") and gives the knowledge facet a
        # clean value to gate on. Retry-on-mismatch steers the weak model onto
        # the list. (Genesis writes wider free-text subroles by a
        # different path; only the materializer enforces the vocabulary.)
        def validate_subrole(e, prefix)
          s = e["subrole"]
          unless ::Harness::Vocations.valid?(s)
            @errors << "#{prefix}: subrole=#{s.inspect} must be one of the VOCATIONS list"
          end
        end

        def validate_properties(e, prefix)
          p = e["properties"]
          return if p.nil?
          unless p.is_a?(Hash)
            @errors << "#{prefix}: properties must be an object if present"
          end
        end

        def validate_budget
          total = Array(@llm["reuse"]).size + Array(@llm["spawn"]).size
          if total > @slots_to_fill
            @errors << "total reuse+spawn=#{total} exceeds SLOTS_TO_FILL=#{@slots_to_fill}"
          end
        end

        def build_output
          {
            "reuse" => Array(@llm["reuse"]).map { |e|
              {
                "character_id" => e["character_id"],
                "subrole"      => e["subrole"],
                "properties"   => e["properties"] || {}
              }
            },
            "spawn" => Array(@llm["spawn"]).map { |e|
              # Drop any name the LLM tried to supply — engine assigns
              # mechanically at apply time.
              {
                "subrole"    => e["subrole"],
                "properties" => e["properties"] || {}
              }
            }
          }
        end

        def raise_if_errors
          raise InvalidOutput, @errors if @errors.any?
        end
      end
    end
  end
end
