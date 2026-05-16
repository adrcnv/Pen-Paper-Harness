require "json"

module Harness
  module Combat
    # One per-NPC slot in a combat round. Builds a tight context (~1K tokens)
    # for THIS NPC ONLY, asks the LLM for a single tool call, and dispatches
    # it through a combat-mode resolver.
    #
    # Returns the tool result hash so the round driver can fold it into the
    # round's per-actor result list (used by end-of-round narration). On
    # malformed LLM output (no tool call extracted), the slot auto-closes
    # via end_turn — don't stall the round on a bad LLM response.
    module NpcTurn
      PROMPT_PATH = ::File.expand_path("../prompts/combat_npc_turn.txt", __dir__)

      def self.run(npc:, scene:, last_round_summary: nil, adapter:, context:, logger: ::Rails.logger)
        state    = scene.combat
        system   = ::File.read(PROMPT_PATH)
        user     = build_user_payload(npc, state, last_round_summary)
        resolver = ::Harness::Resolver.new(context: context, tools: ::Harness::Resolver::NPC_TURN_TOOLS, logger: logger)

        turn = adapter.start_turn(system: system, user: user, tools: resolver.schemas)
        call = nil
        2.times do
          break if turn.complete?
          call = turn.next_tool_call
          break if call
        end

        if call.nil?
          logger&.warn { "[Combat::NpcTurn] #{npc.name} (id=#{npc.id}) emitted no tool call; auto end_turn" }
          return auto_end_turn(npc.id, context)
        end

        # Force the actor_id to THIS NPC — the LLM occasionally gets confused
        # in tight per-actor prompts and tries to act on behalf of someone
        # else. Defense in depth on top of the resolver's current-actor check.
        call.args["actor_id"] = npc.id if call.args.is_a?(::Hash)

        # Defensive normalization for combat NPC resolve calls. The LLM
        # frequently emits resolve with neither stat nor ability_name (or
        # names an exhausted ability), then the tool errors and the slot
        # wastes. Rewrite to unarmed_strike rather than burning the slot.
        normalize_resolve_args!(call, npc, logger) if call.name == "resolve"

        logger&.info { "[Combat::NpcTurn] #{npc.name} (id=#{npc.id}) → #{call.name} args=#{call.args.inspect}" }
        result = resolver.execute(call)

        # Auto-engage retry: the LLM picks a close-range ability without
        # first moving to engaged, the range gate rejects, and the slot
        # wastes. Detect that specific error and recover by inserting the
        # move_to(engaged, target) the LLM should have made first. Costs
        # the move token (which they would have spent anyway) and the
        # original resolve call. No extra LLM round-trip.
        if close_range_error?(result) && (target_id = call.args["target_id"])
          move_result = try_auto_engage(npc, target_id, resolver, state, logger)
          if move_result.is_a?(::Hash) && move_result["ok"]
            logger&.info { "[Combat::NpcTurn] #{npc.name} auto-engaged target=#{target_id}, retrying resolve" }
            result = resolver.execute(call)
          end
        end

        log_result(npc, call, result, logger)
        { "tool" => call.name, "args" => call.args, "result" => result }
      rescue ::StandardError => e
        logger&.warn { "[Combat::NpcTurn] #{npc.name} raised: #{e.class}: #{e.message}" }
        auto_end_turn(npc.id, context)
      end

      # The Resolve tool's range-gate error for close-range abilities. Match
      # against the literal "is melee range (close)" fragment — the error
      # message is constructed in Tools::Resolve#check_combat_range.
      def self.close_range_error?(result)
        result.is_a?(::Hash) && result["error"].to_s.include?("is melee range (close)")
      end

      # Synthesize the move_to(engaged, target_id) call the LLM should have
      # made first. Returns the tool result. If move_to errors (e.g., move
      # already spent), we DON'T retry the resolve — the original error
      # stands.
      def self.try_auto_engage(npc, target_id, resolver, state, logger)
        if state.moved?(npc.id)
          logger&.warn { "[Combat::NpcTurn] #{npc.name} auto-engage skipped: move already spent this round" }
          return { "error" => "move already spent" }
        end
        move_call = ::Harness::LLM::ToolCall.new(
          name: "move_to",
          args: { "actor_id" => npc.id, "position" => "engaged", "target_id" => target_id }
        )
        resolver.execute(move_call)
      end

      # One-line summary of what the slot accomplished. Surfaces errors
      # prominently so range-gate rejections and missing-arg failures don't
      # disappear into a wasted slot without a trace.
      def self.log_result(npc, call, result, logger)
        return unless logger
        if result.is_a?(::Hash) && result["error"]
          logger.warn { "[Combat::NpcTurn] #{npc.name} #{call.name} ERROR: #{result['error']}" }
        elsif call.name == "resolve" && result.is_a?(::Hash)
          summary = "outcome=#{result['outcome']} margin=#{result['margin']} roll=#{result['roll']} vs #{result['against']}"
          summary += " damage=#{result['damage']}" if result["damage"]
          summary += " target_hp=#{result['target_hp']}" if result["target_hp"]
          logger.info { "[Combat::NpcTurn] #{npc.name} resolve(#{result['ability_name'] || result['stat']}) → #{summary}" }
        elsif call.name == "move_to" && result.is_a?(::Hash)
          logger.info { "[Combat::NpcTurn] #{npc.name} move_to #{result['from_position']} → #{result['to_position']}" }
        else
          logger.info { "[Combat::NpcTurn] #{npc.name} #{call.name} → #{result.is_a?(Hash) ? result.slice('ok', 'escaped', 'slot_complete').inspect : result.inspect}" }
        end
      end

      def self.auto_end_turn(actor_id, context)
        result = ::Harness::Combat::Tools::EndTurn.new.call({ "actor_id" => actor_id }, context)
        { "tool" => "end_turn", "args" => { "actor_id" => actor_id }, "result" => result, "auto" => true }
      end

      STATS = %w[strength dexterity constitution intelligence wisdom charisma].freeze

      # Auto-fix the most common combat-NPC resolve failures so the slot
      # actually does something instead of erroring. Rules:
      #   - If neither stat nor ability_name is set, fall back to
      #     ability_name="unarmed_strike" (the hardcoded 1d4 fallback).
      #   - If ability_name names an ability the actor has but it's at
      #     uses_remaining=0, fall back to unarmed_strike (so a fighter
      #     out of Heavy Strike still throws a punch).
      #   - If stat is set but unrecognized, fall back to "strength"
      #     (the most common combat axis).
      # No-op when the call already looks valid.
      def self.normalize_resolve_args!(call, npc, logger = nil)
        args = call.args
        return unless args.is_a?(::Hash)

        ability_name = args["ability_name"].to_s.strip
        stat         = args["stat"].to_s.strip

        if ability_name.empty? && stat.empty?
          args["ability_name"] = "unarmed_strike"
          logger&.info { "[Combat::NpcTurn] #{npc.name} resolve normalized: bare call → ability_name=unarmed_strike" }
          return
        end

        if !ability_name.empty? && ability_name.downcase != "unarmed_strike"
          ability = Array(npc.abilities).find { |a| a["name"].to_s.downcase == ability_name.downcase }
          if ability && ability["uses_remaining"].to_i <= 0
            args.delete("stat")
            args["ability_name"] = "unarmed_strike"
            logger&.info { "[Combat::NpcTurn] #{npc.name} resolve normalized: #{ability_name} depleted → ability_name=unarmed_strike" }
            return
          end
        end

        if ability_name.empty? && !STATS.include?(stat)
          args["stat"] = "strength"
          logger&.info { "[Combat::NpcTurn] #{npc.name} resolve normalized: invalid stat=#{stat.inspect} → stat=strength" }
        end
      end

      def self.build_user_payload(npc, state, last_round_summary)
        my_side = state.side_of(npc.id)
        position_label = state.position_of(npc.id)
        engaged_with_id = state.engaged_with_of(npc.id)
        engaged_with    = engaged_with_id ? ::Character.find_by(id: engaged_with_id) : nil

        allies   = []
        hostiles = []
        state.sides.each do |char_id, side_name|
          next if char_id == npc.id
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

        ::JSON.pretty_generate({
          "you" => {
            "id"           => npc.id,
            "name"         => npc.name,
            "subrole"      => npc.subrole,
            "class"        => npc.character_class,
            "level"        => npc.level,
            "hp"           => "#{npc.current_hp}/#{npc.max_hp}",
            "position"     => position_label,
            "engaged_with" => engaged_with ? { "id" => engaged_with.id, "name" => engaged_with.name } : nil,
            "side"         => my_side,
            "personality"  => (npc.properties.is_a?(::Hash) ? npc.properties["personality"] : nil),
            "abilities"    => Array(npc.abilities).map { |a|
              { "name" => a["name"], "range" => a["range"], "uses_remaining" => a["uses_remaining"], "stat" => a["stat"] }
            }
          },
          "allies"   => allies,
          "hostiles" => hostiles,
          "round"    => state.round,
          "last_round_summary" => last_round_summary
        })
      end
    end
  end
end
