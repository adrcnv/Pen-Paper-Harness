require "json"

module Harness
  module Combat
    # Shared machinery for the two structured combat slots (NpcTurn and
    # PlayerTurn): the tight battlefield payload, resolve-arg normalization,
    # and the mechanical recovery retries that stop a weak-model slip from
    # wasting a slot. One home so the player and NPC slots can't drift.
    module SlotSupport
      STATS = %w[strength dexterity constitution intelligence wisdom charisma].freeze

      module_function

      # The ~1K-token battlefield view for ONE actor. `extra` keys lead the
      # payload (PlayerTurn puts the player's input first).
      def build_user_payload(actor, state, last_round_summary, extra: {})
        my_side = state.side_of(actor.id)
        position_label = state.position_of(actor.id)
        engaged_with_id = state.engaged_with_of(actor.id)
        engaged_with    = engaged_with_id ? ::Character.find_by(id: engaged_with_id) : nil

        allies   = []
        hostiles = []
        state.sides.each do |char_id, side_name|
          next if char_id == actor.id
          char = ::Character.find_by(id: char_id)
          next unless char
          next if char.max_hp.to_i > 0 && char.current_hp.to_i <= 0
          row = {
            "id"           => char.id,
            "name"         => char.name,
            "position"     => state.position_of(char.id),
            "hp"           => "#{char.current_hp}/#{char.max_hp}",
            "engaged_with" => state.engaged_with_of(char.id)
          }
          (side_name == my_side ? allies : hostiles) << row
        end

        ::JSON.pretty_generate(extra.merge({
          "you" => {
            "id"           => actor.id,
            "name"         => actor.name,
            "subrole"      => actor.subrole,
            "class"        => actor.character_class,
            "level"        => actor.level,
            "hp"           => "#{actor.current_hp}/#{actor.max_hp}",
            "position"     => position_label,
            "engaged_with" => engaged_with ? { "id" => engaged_with.id, "name" => engaged_with.name } : nil,
            "side"         => my_side,
            "personality"  => (actor.properties.is_a?(::Hash) ? actor.properties["personality"] : nil),
            "abilities"    => Array(actor.abilities).map { |a|
              { "name" => a["name"], "range" => a["range"], "uses_remaining" => a["uses_remaining"], "stat" => a["stat"] }
            }
          },
          "allies"   => allies,
          "hostiles" => hostiles,
          "round"    => state.round,
          "last_round_summary" => last_round_summary
        }))
      end

      # Normalize → execute → mechanical recovery retries → log. The whole
      # slot-execution sequence both turns share.
      def execute_with_recovery(call, actor, resolver, state, logger: nil, tag: "Combat::Slot")
        normalize_resolve_args!(call, actor, logger: logger, tag: tag) if call.name == "resolve"
        result = resolver.execute(call)

        # Auto-engage retry: a close-range ability without first moving to
        # engaged. Insert the move_to the LLM should have made, retry once.
        if close_range_error?(result) && (target_id = call.args["target_id"])
          move_result = try_auto_engage(actor, target_id, resolver, state, logger: logger, tag: tag)
          if move_result.is_a?(::Hash) && move_result["ok"]
            logger&.info { "[#{tag}] #{actor.name} auto-engaged target=#{target_id}, retrying resolve" }
            result = resolver.execute(call)
          end
        end

        # Unarmed-fallback retry: a weapon/implement ability whose required
        # item tags the actor can't supply. The rejected resolve returns
        # before any state mutation, so the retry spends the token cleanly.
        if tag_gate_error?(result) && call.args["ability_name"].to_s.downcase != "unarmed_strike"
          call.args.delete("stat")
          call.args["ability_name"] = "unarmed_strike"
          logger&.info { "[#{tag}] #{actor.name} weapon ability without a weapon → retrying unarmed_strike" }
          result = resolver.execute(call)
        end

        log_result(actor, call, result, logger: logger, tag: tag)
        result
      end

      # The Resolve tool's range-gate error for close-range abilities. Match
      # against the literal "is melee range (close)" fragment — the error
      # message is constructed in Tools::Resolve#check_combat_range.
      def close_range_error?(result)
        result.is_a?(::Hash) && result["error"].to_s.include?("is melee range (close)")
      end

      # The Resolve tool's tag-gate rejection: a weapon/implement ability whose
      # required item tags the actor can't supply (Tools::Resolve#call, "requires
      # item tags=..."). The remedy is a basic unarmed attack.
      def tag_gate_error?(result)
        result.is_a?(::Hash) && result["error"].to_s.include?("requires item tags")
      end

      # Synthesize the move_to(engaged, target_id) call the LLM should have
      # made first. Returns the tool result. If move_to errors (e.g., move
      # already spent), we DON'T retry the resolve — the original error stands.
      def try_auto_engage(actor, target_id, resolver, state, logger: nil, tag: "Combat::Slot")
        if state.moved?(actor.id)
          logger&.warn { "[#{tag}] #{actor.name} auto-engage skipped: move already spent this round" }
          return { "error" => "move already spent" }
        end
        move_call = ::Harness::LLM::ToolCall.new(
          name: "move_to",
          args: { "actor_id" => actor.id, "position" => "engaged", "target_id" => target_id }
        )
        resolver.execute(move_call)
      end

      # Auto-fix the most common resolve failures so the slot actually does
      # something instead of erroring:
      #   - neither stat nor ability_name → unarmed_strike
      #   - named ability depleted → unarmed_strike
      #   - unrecognized stat → strength
      def normalize_resolve_args!(call, actor, logger: nil, tag: "Combat::Slot")
        args = call.args
        return unless args.is_a?(::Hash)

        ability_name = args["ability_name"].to_s.strip
        stat         = args["stat"].to_s.strip

        if ability_name.empty? && stat.empty?
          args["ability_name"] = "unarmed_strike"
          logger&.info { "[#{tag}] #{actor.name} resolve normalized: bare call → ability_name=unarmed_strike" }
          return
        end

        if !ability_name.empty? && ability_name.downcase != "unarmed_strike"
          ability = Array(actor.abilities).find { |a| a["name"].to_s.downcase == ability_name.downcase }
          if ability && ability["uses_remaining"].to_i <= 0
            args.delete("stat")
            args["ability_name"] = "unarmed_strike"
            logger&.info { "[#{tag}] #{actor.name} resolve normalized: #{ability_name} depleted → ability_name=unarmed_strike" }
            return
          end
        end

        if ability_name.empty? && !STATS.include?(stat)
          args["stat"] = "strength"
          logger&.info { "[#{tag}] #{actor.name} resolve normalized: invalid stat=#{stat.inspect} → stat=strength" }
        end
      end

      # One-line summary of what the slot accomplished. Surfaces errors
      # prominently so gate rejections don't disappear into a wasted slot.
      def log_result(actor, call, result, logger: nil, tag: "Combat::Slot")
        return unless logger
        if result.is_a?(::Hash) && result["error"]
          logger.warn { "[#{tag}] #{actor.name} #{call.name} ERROR: #{result['error']}" }
        elsif call.name == "resolve" && result.is_a?(::Hash)
          summary = "outcome=#{result['outcome']} margin=#{result['margin']} roll=#{result['roll']} vs #{result['against']}"
          summary += " damage=#{result['damage']}" if result["damage"]
          summary += " target_hp=#{result['target_hp']}" if result["target_hp"]
          logger.info { "[#{tag}] #{actor.name} resolve(#{result['ability_name'] || result['stat']}) → #{summary}" }
        elsif call.name == "move_to" && result.is_a?(::Hash)
          logger.info { "[#{tag}] #{actor.name} move_to #{result['from_position']} → #{result['to_position']}" }
        else
          logger.info { "[#{tag}] #{actor.name} #{call.name} → #{result.is_a?(Hash) ? result.slice('ok', 'escaped', 'slot_complete').inspect : result.inspect}" }
        end
      end
    end
  end
end
