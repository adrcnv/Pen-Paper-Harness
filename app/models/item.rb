class Item < ApplicationRecord
  belongs_to :location,  optional: true
  belongs_to :character, optional: true

  validate :anchored_xor_owned

  scope :at,           ->(loc_id) { where(location_id: loc_id) }
  scope :with_subrole, ->(s)      { where(subrole: s) }

  private

  def anchored_xor_owned
    return if location_id.present? ^ character_id.present?
    errors.add(:base, "item must be anchored to a location or owned by a character, not both or neither")
  end
end
