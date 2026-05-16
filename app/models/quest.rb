class Quest < ApplicationRecord
  ALLOWED_STATES = %w[offered active complete abandoned].freeze

  belongs_to :giver,          class_name: "Character", foreign_key: :giver_character_id
  belongs_to :city,           class_name: "Location",  foreign_key: :city_location_id
  belongs_to :created_event,  class_name: "Event",     optional: true
  belongs_to :resolved_event, class_name: "Event",     optional: true

  has_many :quest_steps, -> { order(:position) }, dependent: :destroy

  validates :name,          presence: true
  validates :summary,       presence: true
  validates :archetype_id,  presence: true
  validates :state,         inclusion: { in: ALLOWED_STATES }

  scope :offered, -> { where(state: "offered") }
  scope :active,  -> { where(state: "active")  }
  scope :complete,-> { where(state: "complete")}

  # The first non-fulfilled, non-skipped step. nil if the quest is done.
  def current_step
    quest_steps.where(state: %w[active pending]).order(:position).first
  end

  # True if the player has met the giver — surfaced to /quests visibility.
  # Structural check: any event participation with both the giver and the
  # player in event_participants.
  def player_has_met_giver?
    player = ::Player.first
    return false unless player

    ::Event.joins(:event_participants)
      .where(event_participants: { character_id: giver_character_id })
      .where(id: ::EventParticipant.where(character_id: player.id).select(:event_id))
      .exists?
  end
end
