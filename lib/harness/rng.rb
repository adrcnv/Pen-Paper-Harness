module Harness
  # Session-wide dice RNG, reseedable per turn by Turn::Loop so a rewound
  # turn replays the same rolls (the replay rig's determinism half — the
  # LLM sampler seed is the other, see LLM::Seed). Dice.check defaults its
  # rng to this. Never reset outside the turn boundary.
  module RNG
    class << self
      def reset!(seed)
        @current = Random.new(seed)
      end

      def current
        @current ||= Random.new
      end
    end
  end
end
