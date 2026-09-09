module Harness
  module Combat
    # The tavern-keep guarantee as a rule: only these draw steel on their own.
    # A cook cannot start a fight over a rude word; a guard, a soldier, or a
    # road bandit can. Encounter spawns carry their martial subrole from the
    # role-intent bias, so the list covers them without a separate flag.
    module FightCapable
      SUBROLES = %w[
        guard watchman soldier sellsword mercenary
        bandit raider marauder brigand highwayman
      ].freeze

      module_function

      def fight_capable?(character)
        return false unless character
        SUBROLES.include?(character.subrole.to_s.strip.downcase)
      end
    end
  end
end
