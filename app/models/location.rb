class Location < ApplicationRecord
  # The single terrain vocabulary, sourced from worldgen's fine taxonomy so the
  # LLM (fed this via the {{TERRAINS}} preamble token) speaks the same language
  # the map is generated and stored in. No separate coarse list to drift.
  ALLOWED_TERRAINS   = ::Harness::Worldgen::Terrain::LAND.map(&:to_s).freeze
  KINGDOM_ONLY_KINDS = %w[embassy garrison palace court barracks royal_residence].freeze

  belongs_to :parent,  class_name: "Location", optional: true
  belongs_to :faction, optional: true

  has_many :children, class_name: "Location", foreign_key: :parent_id, dependent: :nullify

  has_many :characters, dependent: :nullify
  has_many :items,      dependent: :nullify
  has_many :events,     dependent: :nullify

  # A settlement is anywhere townsfolk live — cities and their sublocations.
  # The only non-settlement is a wilderness_leaf (a road, a forest, an
  # encounter site). Used by eviction to pick a town to rehome a stray
  # traveler to (lairs are never rehome targets).
  def settlement?
    (properties || {})["kind"] != "wilderness_leaf"
  end

  # Encounter sites whose occupants LIVE there — a bandit lair, a hermit's
  # refuge. As opposed to a social waypoint, where travelers merely pass
  # through. The distinction is the encounter bucket stamped at spawn.
  LAIR_ENCOUNTERS = %w[combat discovery].freeze
  def lair?
    LAIR_ENCOUNTERS.include?((properties || {})["encounter_type"].to_s)
  end

  # Somewhere a freshly-spawned NPC takes as home (home == here): any
  # settlement, or a wilderness lair. A social waypoint or open wild is NOT a
  # residence — NPCs spawned there are transients (homeless → evicted/culled).
  # This is what keeps a fought bandit at his lair (re-encounter = another toll)
  # instead of being rehomed into a peaceful town.
  def residence?
    settlement? || lair?
  end
end
