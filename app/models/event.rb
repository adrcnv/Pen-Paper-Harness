class Event < ApplicationRecord
  ALLOWED_SCOPES = %w[personal local regional kingdom world].freeze

  belongs_to :location, optional: true

  has_many :event_participants, dependent: :destroy
  has_many :participants, through: :event_participants, source: :character

  validates :game_time, presence: true
  validates :scope, inclusion: { in: ALLOWED_SCOPES }

  scope :at_or_after, ->(t) { where("game_time >= ?", t) }
  scope :after,       ->(t) { where("game_time > ?", t) }
  scope :with_scope,  ->(s) { where(scope: s) }
  scope :regional_plus, -> { where(scope: %w[regional kingdom world]) }

  # Excludes introduction events (the meta-audit events created by
  # propose_character/faction/item/location that record "this row was created").
  # Intro events have details["introduction"] set; they're for audit purposes
  # like floor checks (you can't constrain a brand-new character's backstory
  # by their introduction date — they may have history predating it).
  # Use this scope for the floor pass in BackwardAppender; for surfacing
  # events to NPC speech sourcing, use `queryable` instead.
  scope :narrative, -> { where("json_extract(details, '$.introduction') IS NULL") }

  # What query_events surfaces: in-world facts the LLM can read. Includes
  # introduction events (they carry the new entity's `connection` prose in a
  # `narrative` payload — that's the "why this person/place exists" anchor
  # an NPC needs when sourcing their own backstory). Excludes pure bookkeeping
  # markers (mutations, award_xp) which describe system actions, not in-world
  # happenings.
  scope :queryable, -> {
    where("json_extract(details, '$.mutation') IS NULL AND json_extract(details, '$.award_xp') IS NULL")
  }
end
