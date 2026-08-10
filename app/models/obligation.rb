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
  # What still weighs on the parties: open debts AND broken ones (a missed
  # meeting is grudge material, not a closed book). Settled/forgiven drop out.
  scope :outstanding, -> { where(status: %w[open broken]) }
  scope :involving, ->(character_id) { where("debtor_id = ? OR creditor_id = ?", character_id, character_id) }

  # Forward-time parser: the free-text `due` ("tomorrow dawn", "in two
  # hours", "at dusk") → absolute game-minute, baked at write time (dates
  # live in columns, never in wording). Unparseable ("after the barge is
  # loaded") → nil: a condition-due, dunning material but not schedulable.
  DAY = ::Harness::Clock::MINUTES_PER_DAY
  PHASE_MINUTES = {
    "dawn" => 360, "sunrise" => 360, "first light" => 360, "morning" => 360,
    "midday" => 720, "noon" => 720,
    "dusk" => 1020, "sundown" => 1020, "sunset" => 1020, "evening" => 1020,
    "night" => 1320, "nightfall" => 1320, "midnight" => 1440
  }.freeze
  WORD_NUMBERS = {
    "a" => 1, "an" => 1, "one" => 1, "two" => 2, "three" => 3, "four" => 4,
    "five" => 5, "six" => 6, "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10
  }.freeze
  PHASE_RE = /#{PHASE_MINUTES.keys.join('|')}/
  DUE_UNITS = { "hour" => 60, "day" => DAY, "week" => 7 * DAY }.freeze

  def self.parse_due(raw, now)
    s = raw.to_s.strip.downcase
    return nil if s.empty?
    now = now.to_i
    day_start = now - (now % DAY)
    # "in two hours" / "within the hour" / "in 3 days" / "7 hours from now"
    if (m = s.match(/\A(?:(?:in|within)\s+)?(?:the\s+)?(\d+|#{WORD_NUMBERS.keys.join('|')})?\s*(#{DUE_UNITS.keys.join('|')})s?(?:\s+from\s+now)?\z/)) && (m[1] || s.start_with?("in", "within"))
      n = m[1] ? (WORD_NUMBERS[m[1]] || m[1].to_i) : 1
      return now + n * DUE_UNITS[m[2]]
    end
    # "tomorrow" / "tomorrow dawn" / "by tomorrow at dusk" — bare tomorrow
    # lands midday (a neutral middle, not the earliest bound).
    if (m = s.match(/\A(?:by\s+)?tomorrow(?:\s+(?:at\s+)?(#{PHASE_RE}))?\z/))
      return day_start + DAY + (PHASE_MINUTES[m[1]] || 720)
    end
    # "tonight"
    return [ day_start + 1320, now ].max if s == "tonight"
    # "at dawn" / "by dusk" / "dusk" — next occurrence of that phase
    if (m = s.match(/\A(?:at\s+|by\s+)?(#{PHASE_RE})\z/))
      candidate = day_start + PHASE_MINUTES[m[1]]
      return candidate > now ? candidate : candidate + DAY
    end
    nil
  end

  # Breach: a missed meeting cannot be attended late — past due (+ grace)
  # the row flips to broken, mechanically, and becomes grudge material for
  # every consumer. Coins/deed debts do NOT break by lateness; they render
  # as OVERDUE at read time instead.
  BREACH_GRACE = 240
  def self.sweep_breaches!(now, logger: Rails.logger)
    open_now.where(kind: "meet").where(due_time: ...now.to_i - BREACH_GRACE).find_each do |ob|
      ob.update!(status: "broken")
      logger.info { "[Obligation] BROKEN ##{ob.id}: #{ob.terms} (due_time=#{ob.due_time}, now=#{now})" }
    end
  rescue ::StandardError => e
    logger.warn { "[Obligation] breach sweep failed (non-fatal): #{e.class}: #{e.message}" }
  end

  # One compact line from a given character's seat: "You owe Gu 5 coins —
  # haul the grain (due: after the barge is loaded)". Used by the voicing
  # payload and the seeder; the perspective belongs to `viewer_id`. With
  # `now`, a parsed due gains urgency ("(in 2 hours)" / "(OVERDUE)") —
  # computed fresh at read time, never stored.
  def line_for(viewer_id, now: nil)
    mine   = debtor_id == viewer_id
    other  = mine ? creditor : debtor
    amount_part = kind == "coins" ? " #{amount ? "#{amount} coins" : 'coins (amount unfixed)'}" : ""
    head = mine ? "You owe #{other.name}#{amount_part}" : "#{other.name} owes you#{amount_part}"
    parts = [ terms.presence, due.presence && "due: #{due}#{due_urgency(now)}" ].compact
    parts << "BROKEN — never honoured" if status == "broken"
    tail = parts.join(" — ")
    tail.empty? ? head : "#{head} — #{tail}"
  end

  private

  def due_urgency(now)
    return "" unless due_time && now
    delta = due_time - now.to_i
    return " (OVERDUE)" if delta.negative? && status == "open"
    return "" if delta.negative?
    return " (within the hour)" if delta <= 60
    n, unit = delta < DAY ? [ delta / 60, "hour" ] : [ delta / DAY, "day" ]
    " (in #{n} #{unit}#{'s' if n > 1})"
  end
end
