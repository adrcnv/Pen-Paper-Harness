class PendingAppearance < ApplicationRecord
  ALLOWED_SCOPES = %w[local city anywhere].freeze

  belongs_to :triggered_by_event, class_name: "Event",     optional: true
  belongs_to :target_character,   class_name: "Character"
  belongs_to :origin_character,   class_name: "Character", optional: true
  belongs_to :origin_faction,     class_name: "Faction",   optional: true
  belongs_to :actor_character,    class_name: "Character", optional: true
  belongs_to :anchor_location,    class_name: "Location",  optional: true

  validates :scope,        inclusion: { in: ALLOWED_SCOPES }
  validates :intent_text,  presence: true
  validates :earliest_at,  presence: true

  validate :exactly_one_origin_specifier
  validate :faceless_appearance_needs_faction
  validate :anchor_required_unless_anywhere

  scope :unresolved,    -> { where(resolved_at: nil) }
  scope :for_target,    ->(c) { where(target_character_id: c.id) }
  scope :firable_at,    ->(game_time) { where("earliest_at <= ?", game_time) }

  # Marks the row resolved at the given game_time. Idempotent.
  def resolve!(game_time)
    return if resolved_at.present?
    update!(resolved_at: game_time)
  end

  # True if this appearance refers to a specific known character.
  # False = "spawn fresh from origin_faction at fire time."
  def named_actor?
    actor_character_id.present?
  end

  private

  def exactly_one_origin_specifier
    set = [ origin_character_id, origin_faction_id ].count { |v| v.present? }
    errors.add(:base, "origin_character_id and origin_faction_id are mutually exclusive") if set > 1
  end

  def faceless_appearance_needs_faction
    return if named_actor?
    return if origin_faction_id.present?
    errors.add(:base, "faceless appearance (no actor specified) requires origin_faction_id to know what to spawn")
  end

  def anchor_required_unless_anywhere
    return if scope == "anywhere"
    return if anchor_location_id.present?
    errors.add(:anchor_location_id, "is required unless scope=anywhere")
  end
end
