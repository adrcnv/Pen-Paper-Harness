require "json"

module Harness
  module Knowledge
    # Stored-vector envelope + the one place that talks to an embedder.
    #
    # ENVELOPE: the embedding column holds {"m": <model id>, "v": [...]}.
    # The stamp makes a model swap self-healing: a vector produced by another
    # model — or a legacy bare array from before stamping — reads as MISSING
    # and is re-embedded lazily the next time a row is ranked or written
    # (migrate-on-open; no fleet migration, rows nobody recalls never pay).
    #
    # KIND: retrieval models are asymmetric — a fact is embedded as a
    # `passage`, the thing being asked as a `query`; mixing them costs
    # relevance. Callers say which; the embedder decides whether its server
    # wants to hear it (the OpenAI-compat adapter sends input_type on the
    # nvidia dialect and stays silent elsewhere). Embedders that take only a
    # positional argument (test stubs, older adapters) are called plainly.
    module Embedding
      KINDS = %i[query passage].freeze

      module_function

      def pack(vec, model)
        JSON.generate({ "m" => model.to_s, "v" => vec })
      end

      # The vector iff it was produced by `model`; nil for absent, foreign,
      # legacy-bare, or malformed.
      def unpack(raw, model)
        return nil if raw.nil? || raw.to_s.strip.empty?
        parsed = JSON.parse(raw)
        return nil unless parsed.is_a?(Hash) && parsed["m"].to_s == model.to_s
        v = parsed["v"]
        v.is_a?(Array) && !v.empty? ? v : nil
      rescue JSON::ParserError
        nil
      end

      def model_of(embedder)
        id = embedder.respond_to?(:embed_model) ? embedder.embed_model.to_s.strip : ""
        id.empty? ? "unknown" : id
      end

      def embed(embedder, input, kind:)
        raise ArgumentError, "kind must be one of #{KINDS.inspect}" unless KINDS.include?(kind)
        if accepts_kind?(embedder)
          embedder.embed(input, kind: kind)
        else
          embedder.embed(input)
        end
      end

      def accepts_kind?(embedder)
        return false unless embedder.respond_to?(:embed)
        embedder.method(:embed).parameters.any? { |(type, name)| %i[keyrest].include?(type) || (%i[key keyreq].include?(type) && name == :kind) }
      rescue NameError
        false
      end
    end
  end
end
