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
  # encounter site). Used by Whereabouts.settle_transients! to pick a town
  # to anchor a stray traveler to (lairs are never anchor targets).
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
  # residence — NPCs spawned there are transients (anchored if event-engaged,
  # destroyed if pure flavor, at scene exit).
  # This is what keeps a fought bandit at his lair (re-encounter = another toll)
  # instead of being rehomed into a peaceful town.
  def residence?
    settlement? || lair?
  end

  # Article/case-insensitive name lookup: "Upper Huts" and "the Upper Huts"
  # are the SAME place. The tools' exact-string checks let worldbuilding
  # mint an article-variant duplicate row, forking a location and splitting
  # its cast across the copies (first Sonnet tester run, 2026-08-19).
  ARTICLES = %w[the a an].freeze

  def self.name_variants(name)
    base = name.to_s.strip.sub(/\A(?:#{ARTICLES.join('|')})\s+/i, "")
    ([ base ] + ARTICLES.map { |a| "#{a} #{base}" }).map(&:downcase)
  end

  # Exact match wins over an article/case variant when both exist (forked
  # saves predating the guard).
  def self.find_by_name_normalized(name)
    matches = where("LOWER(name) IN (?)", name_variants(name)).to_a
    matches.find { |l| l.name.casecmp?(name.to_s.strip) } || matches.first
  end
end
