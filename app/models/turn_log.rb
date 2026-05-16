class TurnLog < ApplicationRecord
  belongs_to :location, optional: true

  serialize :reasoning_tool_calls, coder: JSON

  validates :turn_number, presence: true

  def self.next_turn_number
    (maximum(:turn_number) || 0) + 1
  end
end
