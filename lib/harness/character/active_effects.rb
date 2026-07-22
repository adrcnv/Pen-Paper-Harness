module Harness
  module Character
    # Timed, itemless effects on a character — the spell twin of item
    # modifiers/effects, deliberately the SAME entry vocabulary
    # (Modifiers-shaped `modifiers`, TriggerRegistry-shaped `effects`, plus a
    # flat `roll_modifier`), so the read chokepoints iterate one more list
    # with zero new logic. Stored on properties["active_effects"].
    #
    # Expiry is LAZY — filtered at read against game_time, no ticking —
    # and hygiene rides writes (expired entries pruned whenever a new one
    # lands). Recasting a live effect REFRESHES it: same-source replaces,
    # never stacks.
    module ActiveEffects
      DEFAULT_DURATION_MINUTES = 30

      class << self
        # Apply an ability's authored `effect:` block to a character.
        # Returns the stored entry, or nil when the ability has no block
        # (utility prose — nothing mechanical to land).
        def apply!(character, ability:, now:)
          spec = ability["effect"]
          return nil unless spec.is_a?(::Hash)

          entry = {
            "source"        => ability["id"],
            "name"          => ability["name"],
            "expires_at"    => now.to_i + (spec["duration_minutes"] || DEFAULT_DURATION_MINUTES).to_i,
            "modifiers"     => Array(spec["modifiers"]),
            "roll_modifier" => spec["roll_modifier"].to_i,
            "effects"       => Array(spec["effects"])
          }

          props = (character.properties || {}).dup
          kept  = Array(props["active_effects"]).reject do |e|
            e["source"] == entry["source"] || expired?(e, now)
          end
          props["active_effects"] = kept + [ entry ]
          character.update!(properties: props)
          entry
        end

        # Unexpired entries for a character at `now`.
        def active_for(character, now:)
          Array((character&.properties || {})["active_effects"]).reject { |e| expired?(e, now) }
        end

        # Sum of flat roll modifiers across live effects (Bless +2, Dread
        # Aura -2 — the bearer's own checks).
        def roll_modifier(character, now:)
          active_for(character, now: now).sum { |e| e["roll_modifier"].to_i }
        end

        def expired?(entry, now)
          entry["expires_at"].to_i <= now.to_i
        end
      end
    end
  end
end
