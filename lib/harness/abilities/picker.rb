module Harness
  module Abilities
    # Interactive ability picker for the player. Used at:
    #   - Character creation: pick initial abilities (count = slot_count_for(1) = 2).
    #   - Each level-up after the first: pick 1 (called from bin/play when
    #     properties.pending_ability_picks > 0, set by XP.levelup!).
    #
    # NPC abilities are still auto-assigned by Assigner / XP.grant_one_ability!
    # — they don't get a menu, they're not the player. Only Player rows reach
    # this picker.
    #
    # Pool: every Library ability whose `classes` includes the character's
    # class AND whose `min_level` <= character.level AND that the character
    # doesn't already own. When the pool is empty, the picker logs and skips.
    #
    # Stamps `uses_remaining` on each chosen ability and appends to
    # character.abilities (JSON column).
    module Picker
      class << self
        def run(character, count:, io: $stdin, out: $stdout, logger: ::Rails.logger)
          return character if count.to_i <= 0
          return character unless character.is_a?(::Player)

          picked = 0
          count.to_i.times do
            owned_ids = Array(character.abilities).map { |a| a["id"] }
            eligible  = Library.for_class(character.character_class, max_level: character.level)
                              .reject { |a| owned_ids.include?(a["id"]) }
            if eligible.empty?
              logger.info { "[Abilities::Picker] no eligible abilities left for #{character.name} (class=#{character.character_class} level=#{character.level})" }
              break
            end
            chosen = prompt_one(character, eligible, io: io, out: out)
            stamped = chosen.merge("uses_remaining" => chosen["uses_per_rest"])
            character.update!(abilities: Array(character.abilities) + [ stamped ])
            picked += 1
            out.puts "  + #{chosen['name']} learned."
            out.puts
          end

          picked
        end

        # Drains character.properties["pending_ability_picks"] by running the
        # picker for that many slots, then clears it. Called from bin/play
        # before each player input cycle. Returns the count actually picked.
        def drain_pending!(character, io: $stdin, out: $stdout, logger: ::Rails.logger)
          return 0 unless character.is_a?(::Player)
          pending = (character.properties || {})["pending_ability_picks"].to_i
          return 0 if pending <= 0

          out.puts "─" * 72
          out.puts "  Level up! #{pending} new #{pending == 1 ? 'ability' : 'abilities'} to choose."
          out.puts "─" * 72

          picked = run(character, count: pending, io: io, out: out, logger: logger)
          # Clear the counter regardless of how many we actually picked
          # (eligible pool may have run dry).
          props = (character.properties || {}).dup
          props.delete("pending_ability_picks")
          character.update!(properties: props)
          picked
        end

        private

        def prompt_one(character, eligible, io:, out:)
          out.puts "Available abilities (#{eligible.size}):"
          eligible.each_with_index do |a, i|
            stat = Library.stat_for_ability(ability: a, character_class: character.character_class)
            stat_lock = a["stat"] ? "  [LOCKED stat: #{stat}]" : "  [stat: #{stat}]"
            extra = []
            extra << "#{a['damage_dice']} dmg" if a["damage_dice"]
            extra << a["range"]
            extra << "area=#{a['area']}" if a["area"]
            extra << "#{a['uses_per_rest']}/rest"
            extra << "min L#{a['min_level']}"
            out.puts "  (#{i + 1}) #{a['name']} #{stat_lock}"
            out.puts "      #{a['description']}"
            out.puts "      #{a['effect_kind']} | #{extra.join(' | ')}"
            out.puts
          end

          loop do
            out.print "Pick (1-#{eligible.size}): "
            input = io.gets.to_s.strip
            n = (Integer(input, 10) rescue nil)
            return eligible[n - 1] if n && (1..eligible.size).cover?(n)
            out.puts "  ! enter a number 1-#{eligible.size}"
          end
        end
      end
    end
  end
end
