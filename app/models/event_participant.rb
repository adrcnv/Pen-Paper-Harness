class EventParticipant < ApplicationRecord
  belongs_to :event
  belongs_to :character

  validates :role, presence: true
end
