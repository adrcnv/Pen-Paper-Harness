module Harness
  # Session-wide dice RNG, reseedable per turn by Turn::Loop so a rewound
  # turn replays the same rolls (the replay rig's determinism half — the
  # LLM sampler seed is the other, see LLM::Seed). Dice.check defaults its
  # rng to this. Never reset outside the turn boundary.
  module RNG
    class << self
      def reset!(seed)
        @current = Random.new(seed)
        # Scene randomness (draws, target counts, spawn rolls) gets its own
        # turn-pinned stream: sharing one with the dice would let scene
        # activity shift dice-roll positions (and vice versa), breaking
        # seed-only reproducibility of each half.
        @scene = Random.new(seed ^ 0x5CE0E5CE)
      end

      def current
        @current ||= Random.new
      end

      def scene
        @scene ||= Random.new
      end
    end
  end
end
