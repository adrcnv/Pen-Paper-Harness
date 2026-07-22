module Harness
  module Spells
    # The closed mutation-atom vocabulary — the wire format shared by
    # hand-authored `atoms:` blocks in the ability library, the composer's
    # output schema, and the commit loop's input. Atoms are addable but never
    # reshapeable: myth-gen and cached blocks in player rows depend on the
    # shape staying stable.
    #
    # Validation here is SHAPE + CRASH CEILINGS only — no balance clamps
    # ("leave it potentially imbalanced, the point is to experience wacky
    # worlds"). A ceiling exists where an absurd value would break the
    # engine or the fiction's continuity, not where it would be unfair.
    module Atoms
      WHO = %w[caster target].freeze

      MAX_ATOMS   = 8
      MAX_MINUTES = 518_400  # a game year — beyond this is a bug, not a wish
      MAX_COINS   = 100_000
      MAX_DICE    = 20       # total dice in one formula
      MAX_SIDES   = 100
      MAX_FLAT    = 100
      TEXT_MAX    = 500
      NAME_MAX    = 80

      # kind => required fields (beyond "kind"). Optional fields are checked
      # only when present.
      KINDS = {
        "damage"           => %w[who dice],
        "heal"             => %w[who dice],
        "timed_effect"     => %w[who name],
        "mutate_character" => %w[who field],
        "mutate_item"      => %w[item field],
        "mint_item"        => %w[name subrole to],
        "create_character" => %w[subrole description],
        "create_location"  => %w[name description],
        "alter_location"   => %w[alteration],
        "teleport"         => %w[who destination],
        "follower"         => %w[who attach],
        "coins"            => %w[who delta],
        "write_knowledge"  => %w[content],
        "write_event"      => %w[summary],
        "reprose"          => %w[who directive],
        "advance_clock"    => %w[minutes],
        "revive"           => %w[who]
      }.freeze

      class << self
        # Validate a whole block. Returns an array of error strings — empty
        # means the block is committable.
        def validate(atoms)
          return [ "atoms must be a non-empty array" ] unless atoms.is_a?(::Array) && atoms.any?
          return [ "too many atoms (#{atoms.size} > #{MAX_ATOMS})" ] if atoms.size > MAX_ATOMS
          atoms.flat_map.with_index { |a, i| validate_atom(a, i) }
        end

        def validate_atom(atom, index)
          label = "atom[#{index}]"
          return [ "#{label} must be an object" ] unless atom.is_a?(::Hash)
          kind = atom["kind"]
          return [ "#{label} unknown kind #{kind.inspect} (valid: #{KINDS.keys.join(', ')})" ] unless KINDS.key?(kind)

          errors = KINDS[kind].filter_map do |f|
            "#{label} (#{kind}) missing #{f.inspect}" if blank?(atom[f])
          end
          return errors if errors.any?

          errors.concat(ceiling_errors(atom, kind, label))
          errors
        end

        private

        def blank?(v)
          v.nil? || (v.respond_to?(:strip) && v.strip.empty?)
        end

        def ceiling_errors(atom, kind, label)
          errors = []
          errors << "#{label} who must be caster or target" if atom.key?("who") && kind != "write_event" && !WHO.include?(atom["who"])

          case kind
          when "damage", "heal"
            errors.concat(dice_errors(atom["dice"], label))
          when "timed_effect"
            if atom["duration_minutes"] && atom["duration_minutes"].to_i > MAX_MINUTES
              errors << "#{label} duration_minutes exceeds ceiling #{MAX_MINUTES}"
            end
            unless atom["roll_modifier"] || array_of_hashes?(atom["modifiers"]) || array_of_hashes?(atom["effects"])
              errors << "#{label} timed_effect needs roll_modifier, modifiers, or effects"
            end
          when "coins"
            unless atom["delta"].is_a?(::Integer) && atom["delta"].abs <= MAX_COINS
              errors << "#{label} delta must be an integer within ±#{MAX_COINS}"
            end
          when "advance_clock"
            unless atom["minutes"].is_a?(::Integer) && atom["minutes"].positive? && atom["minutes"] <= MAX_MINUTES
              errors << "#{label} minutes must be a positive integer <= #{MAX_MINUTES}"
            end
          when "follower"
            errors << "#{label} attach must be true or false" unless [ true, false ].include?(atom["attach"])
          when "write_event"
            if atom["who"] && !(atom["who"].is_a?(::Array) && atom["who"].all? { |w| WHO.include?(w) })
              errors << "#{label} who must be an array of caster/target"
            end
          end

          %w[name subrole destination item].each do |f|
            errors << "#{label} #{f} too long (> #{NAME_MAX})" if atom[f].is_a?(::String) && atom[f].size > NAME_MAX
          end
          %w[description alteration content summary directive].each do |f|
            errors << "#{label} #{f} too long (> #{TEXT_MAX})" if atom[f].is_a?(::String) && atom[f].size > TEXT_MAX
          end
          errors
        end

        def array_of_hashes?(v)
          v.is_a?(::Array) && v.any? && v.all? { |e| e.is_a?(::Hash) }
        end

        # Crash ceiling on dice formulas: parseable, and bounded so a
        # composed "999d999" can't stall the roller or one-shot the world
        # by typo. 20d100 is still absurdly lethal — that's allowed.
        def dice_errors(dice, label)
          terms = ::Harness::Abilities::DiceFormula.parse(dice)
          errors = []
          errors << "#{label} dice count exceeds #{MAX_DICE}" if terms.sum(&:count) > MAX_DICE
          errors << "#{label} dice sides exceed #{MAX_SIDES}" if terms.any? { |t| t.sides > MAX_SIDES }
          errors << "#{label} flat bonus exceeds #{MAX_FLAT}" if terms.any? { |t| t.flat > MAX_FLAT }
          errors
        rescue ::Harness::Abilities::DiceFormula::ParseError => e
          [ "#{label} bad dice formula: #{e.message}" ]
        end
      end
    end
  end
end
