require "rails_helper"

RSpec.describe Harness::Knowledge::CosineRanker do
  # Stub embedder: maps known text → a fixed vector; unknown → a zero vector.
  # Honors the String→vector / Array→[vectors] contract of the real adapter.
  def embedder(map)
    Object.new.tap do |e|
      e.define_singleton_method(:embed) do |input|
        arr  = input.is_a?(Array) ? input : [ input ]
        vecs = arr.map { |t| map.fetch(t, [ 0.0, 0.0 ]) }
        input.is_a?(Array) ? vecs : vecs.first
      end
    end
  end

  # Stub embedders carry no model id, so their stamp is "unknown".
  def fact(content, embedding: nil, game_time: 0, model: "unknown")
    Knowledge.create!(content: content, embedding: embedding && Harness::Knowledge::Embedding.pack(embedding, model), current: true, game_time: game_time)
  end

  let(:log) { Logger.new(IO::NULL) }

  it "orders candidates by cosine similarity to the query" do
    near = fact("the salt tithe was repealed", embedding: [ 1.0, 0.0 ])
    far  = fact("the smithy closes at dusk",    embedding: [ 0.0, 1.0 ])
    emb  = embedder("is there a tithe?" => [ 0.9, 0.1 ])
    out  = described_class.new(embedder: emb, logger: log).call([ far, near ], topic: "is there a tithe?")
    expect(out.map(&:id)).to eq([ near.id, far.id ])
  end

  it "lazily embeds and PERSISTS a candidate missing its stored vector" do
    row = fact("clerk lore", embedding: nil)
    emb = embedder("q" => [ 1.0, 0.0 ], "clerk lore" => [ 1.0, 0.0 ])
    described_class.new(embedder: emb, logger: log).call([ row ], topic: "q")
    expect(JSON.parse(row.reload.embedding)).to eq({ "m" => "unknown", "v" => [ 1.0, 0.0 ] })
  end

  it "treats a vector from ANOTHER model as missing and re-embeds it (migrate-on-open)" do
    row = fact("clerk lore", embedding: [ 0.0, 1.0 ], model: "old-model")
    emb = embedder("q" => [ 1.0, 0.0 ], "clerk lore" => [ 1.0, 0.0 ])
    described_class.new(embedder: emb, logger: log).call([ row ], topic: "q")
    expect(JSON.parse(row.reload.embedding)).to eq({ "m" => "unknown", "v" => [ 1.0, 0.0 ] })
  end

  it "treats a legacy bare-array vector as missing and re-embeds it" do
    row = Knowledge.create!(content: "clerk lore", embedding: JSON.generate([ 0.0, 1.0 ]), current: true, game_time: 0)
    emb = embedder("q" => [ 1.0, 0.0 ], "clerk lore" => [ 1.0, 0.0 ])
    described_class.new(embedder: emb, logger: log).call([ row ], topic: "q")
    expect(JSON.parse(row.reload.embedding)["v"]).to eq([ 1.0, 0.0 ])
  end

  it "passes kind: :query for the topic and :passage for rows when the embedder accepts it" do
    seen = []
    emb = Object.new
    emb.define_singleton_method(:embed) do |input, kind: :passage|
      seen << kind
      input.is_a?(Array) ? input.map { [ 1.0, 0.0 ] } : [ 1.0, 0.0 ]
    end
    row = fact("clerk lore", embedding: nil)
    described_class.new(embedder: emb, logger: log).call([ row ], topic: "q")
    expect(seen).to eq([ :query, :passage ])
  end

  it "falls back to recency when the embedder cannot embed" do
    older = fact("a", game_time: 1, embedding: [ 1.0, 0.0 ])
    newer = fact("b", game_time: 5, embedding: [ 0.0, 1.0 ])
    out   = described_class.new(embedder: Object.new, logger: log).call([ older, newer ], topic: "x")
    expect(out.map(&:id)).to eq([ newer.id, older.id ]) # recency: newest first
  end

  it "falls back to recency when the endpoint returns a nil query vector" do
    older = fact("a", game_time: 1)
    newer = fact("b", game_time: 5)
    down  = Object.new.tap { |e| e.define_singleton_method(:embed) { |_| nil } }
    out   = described_class.new(embedder: down, logger: log).call([ older, newer ], topic: "x")
    expect(out.map(&:id)).to eq([ newer.id, older.id ])
  end

  it "returns an empty set unchanged" do
    expect(described_class.new(embedder: embedder({}), logger: log).call([], topic: "x")).to eq([])
  end
end
