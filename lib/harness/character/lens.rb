module Harness
  module Character
    # Interpretation lens — the structural bias through which a character
    # reads the world. Set once at Hatchery time, lives on
    # `properties.lens`, surfaced inline on query_scene.present_characters
    # and query_character so the reasoning loop can color the NPC's voice
    # when sourcing speech (see the NPC VOICE section in reasoning.txt).
    #
    # Why this exists: the LLM averages toward "obvious correct
    # interpretation" — a cynic, a romantic, a paranoid all end up sounding
    # like the same balanced NPC unless something structural pushes against
    # it. The lens is that push: a HARD conditioning signal the reasoning
    # prompt reads to shape the NPC's tone, what they emphasize, what they
    # suspect, how they color ambiguity in the events they know.
    #
    # Lens does NOT override witnessed fact. A paranoid NPC who saw the
    # player save someone cannot say "the player meant to harm them" — the
    # event is unambiguous. Lens colors what the NPC reads INTO ambiguity:
    # motive when prose is silent, what to feel about it, what to suspect.
    #
    # Distribution leans heavily toward `balanced` so most NPCs read events
    # neutrally. The named lenses are minority colors that produce variance
    # and surprise. Tunable per playtest feel.
    #
    # Lens is set ONCE at character creation. It does not drift, does not
    # re-roll on materialization, and is not affected by events. It is
    # WHO THIS PERSON IS at the level of how they see the world.
    module Lens
      DISTRIBUTION = {
        "balanced"    => 50,
        "cynical"     => 10,
        "bitter"      => 10,
        "credulous"   => 10,
        "optimistic"  => 10,
        "paranoid"    => 5,
        "romantic"    => 5
      }.freeze

      VALID = DISTRIBUTION.keys.to_set.freeze

      class << self
        # Returns a lens string sampled from DISTRIBUTION. Pure function;
        # rng is dependency-injected for deterministic tests.
        def roll(rng: Random.new)
          total = DISTRIBUTION.values.sum
          pick  = rng.rand(total)
          acc   = 0
          DISTRIBUTION.each do |lens, weight|
            acc += weight
            return lens if pick < acc
          end
          DISTRIBUTION.keys.first  # defensive — unreachable given non-empty DISTRIBUTION
        end

        # Idempotent — only sets `properties.lens` if not already present.
        # Re-running on a character that already has a lens leaves it
        # untouched (the lens is who they are; not for re-rolling).
        def apply!(character, rng: Random.new)
          props = character.properties.is_a?(Hash) ? character.properties.dup : {}
          return character if VALID.include?(props["lens"])
          props["lens"] = roll(rng: rng)
          character.update!(properties: props)
          character
        end
      end
    end
  end
end
