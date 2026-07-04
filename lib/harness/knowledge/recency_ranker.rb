module Harness
  module Knowledge
    # Default ranking backend for Query: newest-first, topic-blind. The seam
    # where semantic (cosine over `embedding`) drops in later WITHOUT touching
    # callers — a Ranker is anything responding to `call(rows, topic:)` and
    # returning them reordered. Recency ignores `topic`; the cosine ranker will
    # use it. See knowledge_system_design.md §5/§6.
    module RecencyRanker
      module_function

      def call(rows, topic: nil)
        rows.sort_by { |k| [ -k.game_time.to_i, -k.id.to_i ] }
      end
    end
  end
end
