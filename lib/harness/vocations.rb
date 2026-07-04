module Harness
  # The canonical, closed vocabulary of what a character DOES for a living —
  # the `vocation` facet. Exact-match only (no substring/fuzzy guessing): a
  # knowledge row tagged {vocation: "clerk"} reaches every clerk and no one
  # else. This is the single source of truth so the code that ASSIGNS a
  # vocation (Scene::Materializer) and the code that will MATCH on it
  # (query_knowledge, later) can't drift — same discipline as EQUIPMENT_TAGS.
  #
  # Two halves:
  #   - manifest trades — every proprietor subrole a settlement can seed
  #     (derived from manifest.yml, so adding a building trade extends the
  #     enum for free).
  #   - EXTRAS — vocations that belong to nobody's building: the wandering /
  #     wilderness roles the encounter spawns and world produce.
  module Vocations
    # Non-building vocations. Canonical buckets, deliberately collapsed — the
    # colourful synonyms (marauder, brigand, highwayman) live on the free-text
    # `subrole`; the vocation is the bucket they all fall into ("bandit").
    #
    # Two groups: wilderness/road roles (the encounter spawns), and the generic
    # working commoners a settlement is full of but no building names — the
    # tavern's "labourers", the household "servant". Without these the prompt
    # (which asks for labourers) has no legal bucket and the model retries. They
    # are WHO-gates for ordinary folk: they match only all-null world-general
    # knowledge, never a guild's lore — which is correct.
    EXTRAS = %w[
      bandit mercenary hermit pilgrim wanderer beggar minstrel
      labourer farmhand servant carter cook
    ].freeze

    class << self
      # The whole closed set: manifest trades ∪ extras. Memoized — the manifest
      # is static data loaded once.
      def all
        @all ||= (::Harness::Settlement::Manifest.all_subroles + EXTRAS).uniq.freeze
      end

      def valid?(vocation)
        vocation.is_a?(String) && all.include?(vocation)
      end
    end
  end
end
