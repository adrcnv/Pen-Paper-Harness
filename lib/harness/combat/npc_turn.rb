require "json"

module Harness
  module Combat
    # One per-NPC slot in a combat round. Builds a tight context (~1K tokens)
    # for THIS NPC ONLY, asks the LLM for a single tool call, and dispatches
    # it through a combat-mode resolver. Payload construction, resolve
    # normalization, and the recovery retries live in SlotSupport (shared
    # with PlayerTurn).
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
        user     = SlotSupport.build_user_payload(npc, state, last_round_summary)
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

        logger&.info { "[Combat::NpcTurn] #{npc.name} (id=#{npc.id}) → #{call.name} args=#{call.args.inspect}" }
        result = SlotSupport.execute_with_recovery(call, npc, resolver, state, logger: logger, tag: "Combat::NpcTurn")
        { "tool" => call.name, "args" => call.args, "result" => result }
      rescue ::StandardError => e
        logger&.warn { "[Combat::NpcTurn] #{npc.name} raised: #{e.class}: #{e.message}" }
        auto_end_turn(npc.id, context)
      end

      def self.auto_end_turn(actor_id, context)
        result = ::Harness::Combat::Tools::EndTurn.new.call({ "actor_id" => actor_id }, context)
        { "tool" => "end_turn", "args" => { "actor_id" => actor_id }, "result" => result, "auto" => true }
      end
    end
  end
end
