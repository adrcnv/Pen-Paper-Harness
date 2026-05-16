module Harness
  module Encounters
    # Maps a wilderness_leaf's `encounter_type` to a role-intent + subrole
    # bias used by Hatchery when spawning fresh NPCs at the encounter.
    #
    # Why: the agenda generator at scene entry grounds in a character's
    # `recent_events + properties`. Fresh encounter NPCs have NO events,
    # so without a properties-side intent tag the agenda generator has
    # nothing to anchor on and silently drops the agenda. Likewise the
    # subrole bias steers the LLM (when it picks one) and the Stats
    # materializer (which conditions on subrole) toward the right shape.
    #
    # Three encounter types today (mirror EncounterPolicy buckets).
    # Per-type entry is a small struct: subrole_bias (sample one when
    # caller didn't pass a subrole) + role_intent (merged into properties).
    module RoleIntent
      INTENT = {
        "combat" => {
          subrole_bias: %w[bandit raider marauder brigand highwayman],
          role_intent:  "ambush travelers; demand coin and valuables; attack if refused"
        },
        "discovery" => {
          subrole_bias: %w[hermit recluse pilgrim wanderer keeper],
          role_intent:  "wary of strangers; protective of this place; may share knowledge if respected"
        },
        "social" => {
          subrole_bias: %w[merchant traveler pilgrim family patrol],
          role_intent:  "wants company on the road; trades news; may offer or ask for something"
        }
      }.freeze

      # Returns the entry hash for an encounter_type, or nil for an unknown
      # value. Callers should treat nil as "no injection" — pass through.
      def self.for(encounter_type)
        INTENT[encounter_type.to_s]
      end

      # Pick a subrole_bias for the encounter_type. Returns nil if the
      # encounter_type isn't recognized.
      def self.sample_subrole(encounter_type, rng: Random.new)
        entry = self.for(encounter_type)
        entry && entry[:subrole_bias].sample(random: rng)
      end
    end
  end
end
