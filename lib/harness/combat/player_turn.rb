module Harness
  module Combat
    # The player's combat slot as ONE structured call — the state-machine
    # replacement for running the whole agentic reasoning loop mid-combat
    # (which flailed: ~6 calls per attack, query wandering, gratuitous
    # propose_event). Mirrors NpcTurn — tight payload, single call on the
    # narrow slot surface, SlotSupport recovery — with one difference: the
    # LLM here TRANSLATES the player's input, it does not decide for them.
    # A non-combat input maps to NO call and the slot stays FRESH
    # (Combat::Loop yields again); only a deliberate pass costs end_turn.
    module PlayerTurn
      PROMPT_PATH = ::File.expand_path("../prompts/combat_player_turn.txt", __dir__)

      # Returns [call, result] when an action executed (caller records it on
      # the transcript, same shape as a reasoning tool call), or nil when the
      # input wasn't a combat action / nothing could run.
      def self.run(player:, input:, scene:, adapter:, context:, logger: ::Rails.logger)
        return nil unless adapter && player

        state    = scene.combat
        system   = ::File.read(PROMPT_PATH)
        user     = SlotSupport.build_user_payload(player, state, state.last_round_summary, extra: { "player_input" => input })
        resolver = ::Harness::Resolver.new(context: context, tools: ::Harness::Resolver::NPC_TURN_TOOLS, logger: logger)

        turn = adapter.start_turn(system: system, user: user, tools: SlotSupport.slot_schemas(resolver))
        call = nil
        2.times do
          break if turn.complete?
          call = turn.next_tool_call
          break if call
        end

        if call.nil?
          logger&.info { "[Combat::PlayerTurn] input read as non-action — slot stays fresh :: #{input.to_s[0, 80].inspect}" }
          return nil
        end

        # The slot belongs to the player, whatever actor_id the model wrote.
        call.args["actor_id"] = player.id if call.args.is_a?(::Hash)

        logger&.info { "[Combat::PlayerTurn] #{player.name} → #{call.name} args=#{call.args.inspect}" }
        result = SlotSupport.execute_with_recovery(call, player, resolver, state, logger: logger, tag: "Combat::PlayerTurn")
        [ call, result ]
      rescue ::StandardError => e
        logger&.warn { "[Combat::PlayerTurn] raised: #{e.class}: #{e.message} — slot stays fresh" }
        nil
      end
    end
  end
end
