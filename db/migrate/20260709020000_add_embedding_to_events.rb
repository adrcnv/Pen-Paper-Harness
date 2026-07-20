class AddEmbeddingToEvents < ActiveRecord::Migration[8.0]
  def change
    # Semantic recall over the events store (audit seam #3): cached vector of
    # the event's recall text, lazily backfilled by CosineRanker exactly like
    # knowledge rows. Brings events up to the same retrieval apparatus —
    # before this, an NPC's on-topic memory outside the recency window was
    # unreachable.
    add_column :events, :embedding, :text
  end
end
