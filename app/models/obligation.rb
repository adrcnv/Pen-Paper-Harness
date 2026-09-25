require "zlib"

# One box for everything one character owes another — debts, job payouts,
# promised meetings, sworn favors. Written by the debtor/creditor's own
# reflection when a deal is struck ALOUD in dialogue; consumed by the
# voicing payload (you.debts), the internal-state seeder (agenda material),
# the initiative selector, and transfer_coins (auto-settle). The row IS the
# durable thought — an NPC "keeping track of what they are owed" is this
# table plus its consumers, not a runtime activity.
class Obligation < ApplicationRecord
  KINDS    = %w[coins meet deed].freeze
  # kept: an errand the debtor has decided to honour — they have it to hand
  # and come to deliver it (Whereabouts' errand tier, Errands.deliver!).
  STATUSES = %w[open settled broken forgiven kept].freeze

  belongs_to :debtor,   class_name: "Character"
  belongs_to :creditor, class_name: "Character"

  validates :kind,   inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :terms, presence: true

  scope :open_now,  -> { where(status: "open") }
  # What still weighs on the parties: open debts AND broken ones (a missed
  # meeting is grudge material, not a closed book). Settled/forgiven drop out.
  scope :outstanding, -> { where(status: %w[open broken kept]) }
  scope :involving, ->(character_id) { where("debtor_id = ? OR creditor_id = ?", character_id, character_id) }
  # Errands: what a character owes the PLAYER in things, work or coins — the
  # rows the engine resolves (kept or broken) instead of leaving to prose.
  scope :errands, ->(player) { where(kind: %w[deed coins], creditor_id: player.id).where.not(debtor_id: player.id) }

  # Forward-time parser: the free-text `due` ("tomorrow dawn", "in two
  # hours", "at dusk") → absolute game-minute, baked at write time (dates
  # live in columns, never in wording). Unparseable ("after the barge is
  # loaded") → nil: a condition-due, dunning material but not schedulable.
  DAY = ::Harness::Clock::MINUTES_PER_DAY
  PHASE_MINUTES = {
    "dawn" => 360, "sunrise" => 360, "first light" => 360, "morning" => 360,
    "midday" => 720, "noon" => 720,
    "afternoon" => 840,
    "dusk" => 1020, "sundown" => 1020, "sunset" => 1020, "evening" => 1020,
    "night" => 1320, "nightfall" => 1320, "dark" => 1320, "midnight" => 1440
  }.freeze
  WORD_NUMBERS = {
    "a" => 1, "an" => 1, "one" => 1, "two" => 2, "three" => 3, "four" => 4,
    "five" => 5, "six" => 6, "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10
  }.freeze
  PHASE_RE = /#{PHASE_MINUTES.keys.join('|')}/
  DUE_UNITS = { "hour" => 60, "day" => DAY, "week" => 7 * DAY }.freeze
  # "the third day" counts today as the first: the smith's "come back the
  # third day at dawn" is two dawns off.
  ORDINAL_DAYS = { "next" => 2, "second" => 2, "third" => 3, "fourth" => 4, "fifth" => 5 }.freeze

  def self.parse_due(raw, now)
    s = raw.to_s.strip.downcase
    return nil if s.empty?
    now = now.to_i
    day_start = now - (now % DAY)
    # "in two hours" / "within the hour" / "in 3 days" / "7 hours from now" /
    # "two days from now at dusk" (a phase snaps a day count to that phase)
    if (m = s.match(/\A(?:(?:in|within)\s+)?(?:the\s+)?(\d+|#{WORD_NUMBERS.keys.join('|')})?\s*(#{DUE_UNITS.keys.join('|')})s?(?:\s+from\s+now)?(?:\s+(?:at\s+)?(#{PHASE_RE}))?\z/)) && (m[1] || s.start_with?("in", "within"))
      n = m[1] ? (WORD_NUMBERS[m[1]] || m[1].to_i) : 1
      return day_start + n * DUE_UNITS[m[2]] + PHASE_MINUTES[m[3]] if m[3] && m[2] != "hour"
      return now + n * DUE_UNITS[m[2]]
    end
    # "tomorrow" / "tomorrow dawn" / "by tomorrow at dusk" / "midday tomorrow"
    # — bare tomorrow lands midday (a neutral middle, not the earliest bound).
    if (m = s.match(/\A(?:by\s+|at\s+|before\s+)?(?:(#{PHASE_RE})\s+)?tomorrow(?:\s+(?:at\s+)?(#{PHASE_RE}))?\z/))
      return day_start + DAY + (PHASE_MINUTES[m[1] || m[2]] || 720)
    end
    # "the third day at dawn" / "dawn on the third day" / "the next day"
    if (m = s.match(/\A(?:by\s+|at\s+)?(?:(#{PHASE_RE})\s+)?(?:on\s+)?the\s+(#{ORDINAL_DAYS.keys.join('|')})\s+day(?:\s+(?:at\s+)?(#{PHASE_RE}))?\z/))
      return day_start + (ORDINAL_DAYS[m[2]] - 1) * DAY + (PHASE_MINUTES[m[1] || m[3]] || 720)
    end
    # "tonight"
    return [ day_start + 1320, now ].max if s == "tonight"
    # "at dawn" / "by dusk" / "before dark" / "this afternoon" / "dusk" /
    # "by dusk today" — next occurrence of that phase
    if (m = s.match(/\A(?:at\s+|by\s+|before\s+|this\s+)?(#{PHASE_RE})(?:\s+today)?\z/))
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

  # Errands resolve at due the way meets break: mechanically. When the due
  # window opens (the same lead that starts a meet's counterparty walking)
  # the debtor's standing with the player decides — kept, and they set out
  # with it; or not, and the row breaks once the grace runs out, like a
  # missed meeting. The roll is a stable hash per row (a rewind replays it);
  # the threshold is the stance rung, so dealings up to the window count.
  # A condition-due (no due_time) has no clock: Errands.deliver! rolls it
  # at the next meeting instead. Coins with no amount cannot be counted out.
  # The roll is salted with the terms: ids repeat from one world to the
  # next, and a bare id would give the first promise of every game the same
  # fate.
  KEEP_CHANCE = { "trusting" => 0.95, "warm" => 0.85, "neutral" => 0.7, "guarded" => 0.4, "hostile" => 0.1 }.freeze
  def self.sweep_dues!(now, logger: Rails.logger)
    player = ::Player.first
    return unless player
    t = now.to_i
    errands(player).open_now.where(due_time: ..(t + ::Harness::Scene::Whereabouts::MEET_LEAD)).find_each do |ob|
      next if ob.kind == "coins" && ob.amount.nil?
      if ob.keeps?
        ob.update!(status: "kept")
        logger.info { "[Obligation] KEPT ##{ob.id}: #{ob.terms} (#{ob.debtor.name} #{ob.stance}, due_time=#{ob.due_time}, now=#{t})" }
      elsif ob.due_time < t - BREACH_GRACE
        ob.update!(status: "broken")
        logger.info { "[Obligation] BROKEN ##{ob.id}: #{ob.terms} (#{ob.debtor.name} #{ob.stance}, due_time=#{ob.due_time}, now=#{t})" }
      end
    end
  rescue ::StandardError => e
    logger.warn { "[Obligation] due sweep failed (non-fatal): #{e.class}: #{e.message}" }
  end

  def self.keep_roll(id) = (::Zlib.crc32("keep:#{id}") % 1000) / 1000.0

  def keeps? = self.class.keep_roll("#{id}:#{terms}") < KEEP_CHANCE.fetch(stance, KEEP_CHANCE["neutral"])

  # The debtor's standing rung toward the player (Scene::Active writes it
  # through to the row); neutral until a scene has moved it.
  def stance
    props = debtor.properties
    st = props.is_a?(::Hash) ? props["stance"] : nil
    KEEP_CHANCE.key?(st) ? st : "neutral"
  end

  # One compact line from a given character's seat: "You owe Gu 5 coins —
  # haul the grain (due: after the barge is loaded)". Used by the voicing
  # payload and the seeder; the perspective belongs to `viewer_id`. With
  # `now`, a parsed due gains urgency ("(in 2 hours)" / "(OVERDUE)") —
  # computed fresh at read time, never stored.
  # `name:` renders the viewer in third person ("Bogumil owes ...") — for
  # LLM payloads, where second-person strings get echoed back as "I"
  # (register pollution). Without it, the player-facing "You owe ..." form.
  def line_for(viewer_id, now: nil, name: nil)
    mine   = debtor_id == viewer_id
    other  = mine ? creditor : debtor
    amount_part = kind == "coins" ? " #{amount ? "#{amount} coins" : 'coins (amount unfixed)'}" : ""
    head = mine ? "#{name || 'You'} owe#{name ? 's' : ''} #{other.name}#{amount_part}" : "#{other.name} owes #{name || 'you'}#{amount_part}"
    parts = [ terms.presence, due.presence && "due: #{due}#{due_urgency(now)}" ].compact
    parts << breach_note(viewer_id, name) if status == "broken"
    # The debtor's own resolve, for their own seat only: the other party
    # sees a promise pending, not the roll (deeds-2: the sheet read KEPT two
    # hours before the thing was due).
    parts << "KEPT — will make good when it falls due" if status == "kept" && mine
    tail = parts.join(" — ")
    tail.empty? ? head : "#{head} — #{tail}"
  end

  private

  # The machine delivers the counterparty for the window (Whereabouts' meet
  # tier), so a breach is the PLAYER's absence whichever seat owed the
  # meeting — the line says who never came, from either seat. A row with no
  # player party (none is written today) keeps the neutral wording.
  def breach_note(viewer_id, name)
    unless kind == "meet"
      who = debtor_id == viewer_id && name.nil? ? "you" : debtor.name
      return "BROKEN — #{who} never made good"
    end
    player = [ debtor, creditor ].find { |c| c.is_a?(::Player) }
    return "BROKEN — never honoured" unless player
    who = player.id == viewer_id && name.nil? ? "you" : player.name
    "BROKEN — #{who} never came"
  end

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
