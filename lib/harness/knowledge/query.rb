module Harness
  module Knowledge
    # The read primitive over the KNOWLEDGE store: "what standing facts could
    # THIS character know, most relevant first?" Both recall (surface into a
    # speaking turn) and capture (dedup before writing) go through here.
    #
    # Two stages, cleanly split:
    #   1. FACET FILTER (mechanical SQL) — the exact WHERE gate. A row matches
    #      when every one of its non-null facets matches the character; a null
    #      facet is a wildcard. This is the hard categorical wall (a clerk never
    #      sees the fishmonger's lore).
    #   2. RANK (swappable) — order the survivors. Default is recency; the
    #      cosine backend slots in behind the same interface once embeddings
    #      exist. `topic` is threaded through for that future ranker.
    #
    # Facet-only for now: `topic` is accepted but the default ranker ignores it.
    module Query
      DEFAULT_LIMIT = 10

      module_function

      # Facts `character` could know, ranked, capped at `limit`.
      def for(character:, topic: nil, limit: DEFAULT_LIMIT, ranker: RecencyRanker)
        candidates = candidates_for(character)
        ranker.call(candidates, topic: topic).first(limit)
      end

      # The facet-gated candidate set (unranked). Kept public so capture can
      # reuse the exact same gate when checking "does this already exist?".
      def candidates_for(character)
        scope = ::Knowledge.current
        scope = scope.where("knowledge.subrole IS NULL OR knowledge.subrole = ?", character.subrole)
        scope = scope.where("knowledge.min_int IS NULL OR knowledge.min_int <= ?", character.intelligence)
        scope = scope.where("knowledge.social_class IS NULL OR knowledge.social_class = ?", character.social_class)
        scope = scope.where("knowledge.faction IS NULL OR knowledge.faction = ?", character.faction)
        scope = apply_place_gate(scope, character)
        scope.to_a
      end

      # Place facet: a fact scoped to location L is known by anyone within L's
      # subtree — i.e. L must be the character's location OR one of its
      # ancestors. So the matching set is the character's location up-chain to
      # the root. A city-scoped fact reaches every sublocation; a
      # sublocation-scoped fact never leaks to a sibling. Location-less
      # characters match only world-general (null-location) rows.
      def apply_place_gate(scope, character)
        ancestry = ancestor_location_ids(character.location)
        if ancestry.any?
          scope.where("knowledge.location_id IS NULL OR knowledge.location_id IN (?)", ancestry)
        else
          scope.where("knowledge.location_id IS NULL")
        end
      end

      def ancestor_location_ids(location)
        ids = []
        current = location
        while current
          ids << current.id
          current = current.parent
        end
        ids
      end
    end
  end
end
