module Harness
  module Knowledge
    # Step 3 — the RELEVANCE GATE. Between mechanical recall (which returns
    # SOMETHING for any query — KNN/facet has no natural "nothing on point"
    # verdict) and the speak turn, a tiny LLM call strips the candidates down to
    # the facts that actually bear on the player's line. Two jobs:
    #   1. keep the weak speak-model's context clean (noise poisons voicing);
    #   2. its "nothing relevant" verdict is the honest miss signal a static
    #      cosine threshold can't give (magnitudes are uncalibrated across
    #      queries) — later wired as the capture trigger.
    #
    # Currency is OUTPUT tokens: this reads a handful of facts and emits a short
    # id list, so it is nearly free even though it's an extra call.
    #
    # Fail-safe: any parse/LLM failure returns [] (recall nothing) rather than
    # dumping unfiltered candidates into speak — a missed recall degrades
    # gracefully (the NPC re-invents, capture catches it); leaked noise does not.
    class Gate
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/knowledge_gate.txt")

      def self.run(**kwargs) = new(**kwargs).run

      # facts: an ordered list of records responding to #id and #content.
      def initialize(llm:, topic:, facts:, logger: Rails.logger)
        @llm    = llm
        @topic  = topic.to_s
        @facts  = Array(facts)
        @logger = logger
      end

      # Returns the subset of `facts` the gate judged relevant (possibly empty).
      def run
        return [] if @facts.empty?

        raw = ::Harness::CostTracker.in_subsystem(:knowledge_gate) do
          @llm.complete(system: preamble, user: user_message)
        end
        ids = relevant_ids(raw)
        approved = @facts.select { |f| ids.include?(f.id) }
        @logger.info { "[Knowledge::Gate] #{@facts.size} candidate(s) → #{approved.size} relevant #{approved.map(&:id).inspect}" }
        approved
      rescue StandardError => e
        @logger.warn { "[Knowledge::Gate] failed (recall nothing): #{e.class}: #{e.message}" }
        []
      end

      private

      def user_message
        payload = {
          "player_line" => @topic,
          "facts"       => @facts.map { |f| { "id" => f.id, "text" => f.content } }
        }
        "INPUT:\n#{JSON.pretty_generate(payload)}"
      end

      def relevant_ids(raw)
        parsed = ::Harness::LLM::JsonResponse.parse(raw)
        Array(parsed.is_a?(::Hash) ? parsed["relevant"] : nil).select { |x| x.is_a?(Integer) }
      rescue StandardError => e
        @logger.warn { "[Knowledge::Gate] parse failed: #{e.class}: #{e.message}" }
        []
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
