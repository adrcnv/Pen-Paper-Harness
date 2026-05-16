class Character < ApplicationRecord
  # STI base. Concrete classes: Npc, Player. See:
  #   app/models/npc.rb     — NPCs; materialized in scenes
  #   app/models/player.rb  — the player's current body
  #
  # Shared mechanics (location, stats, items, event participation) live here
  # so the same machinery operates on player and NPC uniformly.

  STATS              = %w[strength dexterity constitution intelligence wisdom charisma].freeze
  DEFAULT_STAT_VALUE = 10
  DEFAULT_LEVEL      = 1

  # Abilities are a JSON array of hashes; each entry is a row from
  # lib/harness/abilities/library.yml as picked by Harness::Abilities::Assigner
  # at character creation (Hatchery). nil = legacy data that predates the
  # eager Hatchery seam; [] = assigned, has none (the common case for
  # commoners and level-1 NPCs); [...] = has these.
  serialize :abilities, coder: JSON

  belongs_to :location, optional: true

  has_many :event_participants, foreign_key: :character_id, dependent: :nullify
  has_many :events,             through: :event_participants
  has_many :items,              dependent: :nullify

  scope :at,           ->(loc_id) { where(location_id: loc_id) }
  scope :with_subrole, ->(s)      { where(subrole: s) }
  scope :prop_eq, ->(k, v) {
    where("json_extract(properties, ?) = ?", "$.#{k}", v)
  }

  # Returns the stat value if set, otherwise DEFAULT_STAT_VALUE. Characters
  # with nil-statted columns still participate in mechanical checks at the
  # average baseline — no need to populate stats for every tavern patron
  # up front.
  def stat(name)
    return nil unless STATS.include?(name.to_s)
    read_attribute(name) || DEFAULT_STAT_VALUE
  end
end
