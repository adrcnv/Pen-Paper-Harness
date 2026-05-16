module Harness
  # Interactive CLI prompt flow run before turn 1 of a new game. Pure Ruby;
  # no LLM. IO is injected so tests can drive it with StringIO.
  #
  # Returns a hash {name:, stats:, character_class:} that bin/play uses to
  # persist the Player row + spawn at a random worldgen city.
  #
  # Two paths:
  #   - roll: 2d10 per stat (range 2-20, mean 11). Higher variance than 3d6,
  #     real downside on a 2, real upside on a 19+. Player picks ONE stat to
  #     reroll; the new value commits — no take-backs.
  #   - distribute: DISTRIBUTE_TOTAL points to spread across six stats, each
  #     min DISTRIBUTE_MIN max DISTRIBUTE_MAX. Predictable, modest, lower
  #     ceiling than a lucky roll.
  #
  # Class is picked AFTER stats so the player can react to whatever rolls
  # they got. The list mirrors the structural class roster defined in
  # lib/harness/abilities/classes.yml (minus commoner — not offered as a
  # player choice; players pick to BE someone). Each class has a primary
  # stat and a hit_die that drive ability access and HP scaling at
  # Hatchery time.
  module CharacterCreation
    CLASSES = %w[fighter rogue ranger mage sorcerer cleric].freeze
    STATS   = %i[strength dexterity constitution intelligence wisdom charisma].freeze

    DISTRIBUTE_TOTAL = 60
    DISTRIBUTE_MIN   = 6
    DISTRIBUTE_MAX   = 15

    ROLL_DICE = 2
    ROLL_DIE  = 10

    def self.run(io: $stdin, out: $stdout, rng: Random.new)
      out.puts "─" * 72
      out.puts "  Character Creation"
      out.puts "─" * 72

      name            = prompt_name(io, out)
      stats           = prompt_stats(io, out, rng: rng)
      character_class = prompt_class(io, out)

      out.puts
      out.puts "  → #{name}, the #{character_class.capitalize} (#{stats_summary(stats)})"
      out.puts

      { name: name, stats: stats, character_class: character_class }
    end

    def self.prompt_name(io, out)
      out.puts
      out.puts "What is your character's name? (default: Hero)"
      out.print "> "
      input = io.gets.to_s.strip
      input.empty? ? "Hero" : input
    end

    def self.prompt_stats(io, out, rng:)
      out.puts
      out.puts "How will you determine your stats?"
      out.puts "  (1) Roll the dice (#{ROLL_DICE}d#{ROLL_DIE} per stat, range #{ROLL_DICE}-#{ROLL_DICE * ROLL_DIE} — high variance; one stat reroll allowed)"
      out.puts "  (2) Distribute points (#{DISTRIBUTE_TOTAL} to spend, min #{DISTRIBUTE_MIN} max #{DISTRIBUTE_MAX} per stat — predictable, modest)"

      pick = prompt_choice(io, out, range: 1..2)
      case pick
      when 1 then roll_stats(io, out, rng: rng)
      when 2 then distribute_stats(io, out)
      end
    end

    def self.roll_stats(io, out, rng:)
      stats = STATS.each_with_object({}) { |s, h| h[s] = roll(rng) }
      out.puts
      out.puts "Rolled stats:"
      print_stats(out, stats)
      out.puts
      out.puts "  (a) accept these"
      out.puts "  (r) reroll ONE stat (single use; new value commits)"

      choice = prompt_letter(io, out, allowed: %w[a r])
      return stats if choice == "a"

      out.puts
      out.puts "Which stat to reroll?"
      STATS.each_with_index do |s, i|
        out.puts "  (#{i + 1}) #{label(s)} = #{stats[s]}"
      end
      pick = prompt_choice(io, out, range: 1..STATS.size)
      target = STATS[pick - 1]
      old    = stats[target]
      stats[target] = roll(rng)

      out.puts
      out.puts "  #{label(target)}: #{old} → #{stats[target]}"
      out.puts
      out.puts "Final stats:"
      print_stats(out, stats)
      stats
    end

    # Per-stat prompted entry with running budget. The last stat is auto-set
    # to whatever's left, validated against the min/max range; a bad final
    # value restarts the whole distribution rather than asking the player to
    # back-track (back-track UI is more code than the player saving 30 seconds
    # is worth).
    def self.distribute_stats(io, out)
      out.puts
      out.puts "Distribute #{DISTRIBUTE_TOTAL} points across six stats (each min #{DISTRIBUTE_MIN}, max #{DISTRIBUTE_MAX})."
      stats     = {}
      remaining = DISTRIBUTE_TOTAL

      STATS.each_with_index do |stat, i|
        last_stat = (i == STATS.size - 1)

        if last_stat
          if remaining < DISTRIBUTE_MIN || remaining > DISTRIBUTE_MAX
            out.puts "  ! ran out of valid budget for #{label(stat)} (would be #{remaining}, must be #{DISTRIBUTE_MIN}-#{DISTRIBUTE_MAX}). Restarting."
            return distribute_stats(io, out)
          end
          stats[stat] = remaining
          out.puts "  #{label(stat)} = #{remaining} (auto-balanced from remaining)"
          remaining = 0
          next
        end

        loop do
          out.print "  #{label(stat)} (#{DISTRIBUTE_MIN}-#{DISTRIBUTE_MAX}, #{remaining} pts left): "
          input = io.gets.to_s.strip
          value = (Integer(input, 10) rescue nil)

          if value.nil? || value < DISTRIBUTE_MIN || value > DISTRIBUTE_MAX
            out.puts "  ! enter an integer #{DISTRIBUTE_MIN}-#{DISTRIBUTE_MAX}"
            next
          end
          if value > remaining
            out.puts "  ! only #{remaining} pts left"
            next
          end

          remaining_stats     = STATS.size - i - 1
          min_remaining_total = remaining_stats * DISTRIBUTE_MIN
          max_remaining_total = remaining_stats * DISTRIBUTE_MAX

          if remaining - value < min_remaining_total
            out.puts "  ! that leaves too little for the remaining #{remaining_stats} stat(s) (min #{min_remaining_total} pts each at #{DISTRIBUTE_MIN})"
            next
          end
          if remaining - value > max_remaining_total
            out.puts "  ! that leaves too much for the remaining #{remaining_stats} stat(s) (cap is #{max_remaining_total} pts at #{DISTRIBUTE_MAX} each)"
            next
          end

          stats[stat] = value
          remaining  -= value
          break
        end
      end

      out.puts
      out.puts "Final stats:"
      print_stats(out, stats)
      stats
    end

    def self.prompt_class(io, out)
      out.puts
      out.puts "Pick a class:"
      CLASSES.each_with_index do |c, i|
        out.puts "  (#{i + 1}) #{c.capitalize}"
      end
      pick = prompt_choice(io, out, range: 1..CLASSES.size)
      CLASSES[pick - 1]
    end

    # ---- helpers ----

    def self.roll(rng)
      ROLL_DICE.times.sum { rng.rand(1..ROLL_DIE) }
    end

    def self.label(stat)
      stat.to_s.upcase[0..2]
    end

    def self.stats_summary(stats)
      STATS.map { |s| "#{label(s)}=#{stats[s]}" }.join(" ")
    end

    def self.print_stats(out, stats)
      STATS.each { |s| out.puts "  #{label(s)} = #{stats[s]}" }
    end

    def self.prompt_choice(io, out, range:)
      loop do
        out.print "> "
        input = io.gets.to_s.strip
        n = (Integer(input, 10) rescue nil)
        return n if n && range.include?(n)
        out.puts "  ! enter a number #{range.min}-#{range.max}"
      end
    end

    def self.prompt_letter(io, out, allowed:)
      loop do
        out.print "> "
        input = io.gets.to_s.strip.downcase
        return input if allowed.include?(input)
        out.puts "  ! enter one of: #{allowed.join(', ')}"
      end
    end
  end
end
