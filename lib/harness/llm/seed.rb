module Harness
  module LLM
    # Per-turn sampler seed, set by Turn::Loop at turn start and read by
    # OpenAICompatAdapter into every chat request ("seed" payload field —
    # llama.cpp honors it; a strict OpenAI server ignores it). nil = no
    # pinning (test contexts that never run a turn). Same seed across a
    # turn's calls is fine: each request samples independently.
    module Seed
      class << self
        attr_accessor :current
      end
    end
  end
end
