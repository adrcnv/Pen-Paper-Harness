class QuestStep < ApplicationRecord
  ALLOWED_STATES            = %w[pending active fulfilled skipped].freeze
  ALLOWED_FULFILLMENT_KINDS = %w[information item_in_inventory character_dead character_at_location].freeze

  belongs_to :quest
  belongs_to :target_character, class_name: "Character", optional: true
  belongs_to :target_item,      class_name: "Item",      optional: true
  belongs_to :target_location,  class_name: "Location",  optional: true

  validates :position,         presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :description,       presence: true
  validates :state,             inclusion: { in: ALLOWED_STATES }
  validates :fulfillment_kind,  inclusion: { in: ALLOWED_FULFILLMENT_KINDS }
  validate  :targets_match_kind

  scope :pending,   -> { where(state: "pending")   }
  scope :active,    -> { where(state: "active")    }
  scope :fulfilled, -> { where(state: "fulfilled") }
  scope :skipped,   -> { where(state: "skipped")   }

  private

  def targets_match_kind
    case fulfillment_kind
    when "information"
      errors.add(:target_character_id, "required for information") if target_character_id.blank?
    when "item_in_inventory"
      errors.add(:target_item_id, "required for item_in_inventory") if target_item_id.blank?
    when "character_dead"
      errors.add(:target_character_id, "required for character_dead") if target_character_id.blank?
    when "character_at_location"
      errors.add(:target_character_id, "required for character_at_location") if target_character_id.blank?
      errors.add(:target_location_id,  "required for character_at_location") if target_location_id.blank?
    end
  end
end
