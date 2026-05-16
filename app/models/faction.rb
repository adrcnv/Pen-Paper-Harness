class Faction < ApplicationRecord
  KINGDOM_SUBROLES = %w[kingdom trade_league empire theocracy tribal_confederation].freeze
  NON_KINGDOM_SUBROLES = %w[
    thieves_guild merchants_guild mercenary_company religious_order
    smuggling_ring crime_family trade_association fraternal_order cult
  ].freeze

  has_many :locations, dependent: :nullify

  scope :with_subrole, ->(s) { where(subrole: s) }
  scope :kingdoms,     ->    { where(is_kingdom: true) }

  scope :prop_eq, ->(k, v) {
    where("json_extract(properties, ?) = ?", "$.#{k}", v)
  }
end
