module Harness
  module Knowledge
    # Default ranking backend for Query: newest-first, topic-blind. A Ranker
    # is anything responding to `call(rows, topic:)` and returning them
    # reordered — CosineRanker (semantic, over `embedding`) is the other
    # backend. Recency ignores `topic`; the cosine ranker uses it.
    module RecencyRanker
      module_function

      def call(rows, topic: nil)
        rows.sort_by { |k| [ -k.game_time.to_i, -k.id.to_i ] }
      end
    end
  end
end
