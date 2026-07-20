module Harness
  module Knowledge
    # Semantic ranking backend for Query — the cosine reranker that slots into
    # the RecencyRanker seam (responds to `call(rows, topic:)`, returns them
    # reordered). Unlike RecencyRanker it holds state (an embedder), so it's an
    # instance, not a module: callers pass `ranker: CosineRanker.new(embedder:)`.
    #
    # Pipeline (the facet SQL gate already ran in Query#candidates_for — this
    # only reorders a bounded, facet-matched set, which is why brute-force is
    # fine and no ANN index is needed until a facet outgrows it):
    #   1. embed the query text once (one /v1/embeddings call);
    #   2. lazily backfill any candidate row missing its stored vector (one
    #      batched call, persisted so it's paid once), then
    #   3. sort by cosine(query, fact) descending.
    #
    # Cosine is a COARSE pre-sort: it decides which top-k the relevance gate
    # sees, not the final answer — the gate does precision. So thin embeddings
    # (the local decoder's compressed 0.80–0.85 band) are good enough here.
    #
    # Fail-safe: no embedder / a down endpoint / a nil vector → fall back to
    # RecencyRanker. A dead embedding server must never kill recall.
    class CosineRanker
      def initialize(embedder:, fallback: RecencyRanker, logger: Rails.logger)
        @embedder = embedder
        @fallback = fallback
        @logger   = logger
        @cache    = {}
      end

      def call(rows, topic: nil)
        return rows if rows.empty?
        return degrade(rows, topic, "embedder has no #embed") unless @embedder.respond_to?(:embed)

        q = @embedder.embed(topic.to_s)
        return degrade(rows, topic, "nil/empty query vector") if q.nil? || q.empty?

        ensure_embeddings(rows)
        rows.sort_by { |r| -similarity(q, vector_for(r)) }
      rescue StandardError => e
        degrade(rows, topic, "#{e.class}: #{e.message}")
      end

      private

      def degrade(rows, topic, why)
        @logger.warn { "[Knowledge::CosineRanker] recency fallback — #{why}" }
        @fallback.call(rows, topic: topic)
      end

      # Embed candidates that don't yet have a stored vector, in ONE batched
      # call, and persist (JSON in the embedding column) so later recalls skip
      # the work. Self-healing backfill; the facet gate bounds the set size.
      def ensure_embeddings(rows)
        missing = rows.reject { |r| stored_vector(r) }
        return if missing.empty?
        vecs = @embedder.embed(missing.map(&:content))
        missing.zip(Array(vecs)).each do |row, vec|
          next if vec.nil? || vec.empty?
          row.update_column(:embedding, JSON.generate(vec)) # cache write: skip callbacks/timestamps
          @cache[cache_key(row)] = vec
        end
      end

      def vector_for(row)
        stored_vector(row) || []
      end

      # Cache key carries the model class: one ranker instance now ranks BOTH
      # stores (knowledge rows and event rows), and bare ids collide across
      # tables (Knowledge#1 vs Event#1 — the mill-memory bug).
      def cache_key(row)
        [ row.class.name, row.id ]
      end

      def stored_vector(row)
        key = cache_key(row)
        return @cache[key] if @cache.key?(key)
        raw = row.embedding
        @cache[key] = (raw.nil? || raw.to_s.strip.empty? ? nil : JSON.parse(raw))
      rescue JSON::ParserError
        @cache[key] = nil
      end

      # True cosine — correct whether or not the server pre-normalizes; cheap
      # over a facet-gated handful. Missing/mismatched/zero vectors → -1 so they
      # sink below anything comparable. Class-level so Capture's revision scan
      # can reuse the same math without instantiating a ranker.
      def self.similarity(a, b)
        return -1.0 if a.nil? || b.nil? || a.empty? || b.empty? || a.size != b.size
        dot = 0.0
        na  = 0.0
        nb  = 0.0
        a.each_index do |i|
          av = a[i]
          bv = b[i]
          dot += av * bv
          na  += av * av
          nb  += bv * bv
        end
        return -1.0 if na.zero? || nb.zero?
        dot / (Math.sqrt(na) * Math.sqrt(nb))
      end

      def similarity(a, b) = self.class.similarity(a, b)
    end
  end
end
