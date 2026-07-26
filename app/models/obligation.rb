# One box for everything one character owes another — debts, job payouts,
# promised meetings, sworn favors. Written by the debtor/creditor's own
# reflection when a deal is struck ALOUD in dialogue; consumed by the
# voicing payload (you.debts), the internal-state seeder (agenda material),
# the initiative selector, and transfer_coins (auto-settle). The row IS the
# durable thought — an NPC "keeping track of what they are owed" is this
# table plus its consumers, not a runtime activity.
class Obligation < ApplicationRecord
  KINDS    = %w[coins meet deed].freeze
  STATUSES = %w[open settled broken forgiven].freeze

  belongs_to :debtor,   class_name: "Character"
  belongs_to :creditor, class_name: "Character"

  validates :kind,   inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :terms, presence: true

  scope :open_now,  -> { where(status: "open") }
  scope :involving, ->(character_id) { where("debtor_id = ? OR creditor_id = ?", character_id, character_id) }

  # One compact line from a given character's seat: "You owe Gu 5 coins —
  # haul the grain (due: after the barge is loaded)". Used by the voicing
  # payload and the seeder; the perspective belongs to `viewer_id`.
  def line_for(viewer_id)
    mine   = debtor_id == viewer_id
    other  = mine ? creditor : debtor
    amount_part = kind == "coins" ? " #{amount ? "#{amount} coins" : 'coins (amount unfixed)'}" : ""
    head = mine ? "You owe #{other.name}#{amount_part}" : "#{other.name} owes you#{amount_part}"
    tail = [ terms.presence, due.presence && "due: #{due}" ].compact.join(" — ")
    tail.empty? ? head : "#{head} — #{tail}"
  end
end
