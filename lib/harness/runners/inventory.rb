module Harness
  module Runners
    # Take / drop / give / pay. One structured call picks the action + ids;
    # Ruby drives the matching tool. Mostly deterministic once the model maps
    # "give Marnie 5 coins" → transfer_coins(player → marnie, 5).
    class Inventory < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/inventory.txt")

      def run(context:, scene:, input:, step:)
        player = ::Player.first
        return redispatch("no player row") unless player

        spec = decide(context, input, step, scene, player)
        return redispatch("inventory emit unparseable") if spec.nil?

        resolver = resolver_for(context)
        tcs = []
        from = spec["from_id"] || player.id

        # A null id is the resolver saying "this thing isn't in the world"
        # (an ale that exists only in staged dialogue). That's deterministic —
        # re-planning reproduces it — so skip the step and let the chain
        # continue rather than burning the redispatch cap and killing the
        # independent steps behind it.
        case spec["action"]
        when "pickup"
          return skip("pickup without item_id", tcs) unless spec["item_id"]
          execute_tool(resolver, "pickup", { "item_id" => spec["item_id"], "by_character_id" => player.id }, into: tcs)
        when "drop"
          return skip("drop without item_id", tcs) unless spec["item_id"]
          execute_tool(resolver, "drop", { "item_id" => spec["item_id"], "by_character_id" => player.id }, into: tcs)
        when "give"
          return skip("give without item_id/to_id", tcs) unless spec["item_id"] && spec["to_id"]
          execute_tool(resolver, "give_item", { "item_id" => spec["item_id"], "from_id" => from, "to_id" => spec["to_id"], "reason" => spec["reason"] }, into: tcs)
        when "transfer_coins"
          return skip("transfer without amount", tcs) unless spec["amount"]
          if spec["to_id"]
            execute_tool(resolver, "transfer_coins", { "from_id" => from, "to_id" => spec["to_id"], "amount" => spec["amount"], "reason" => spec["reason"] }, into: tcs)
          else
            # No recipient resolved ("put 5 coins on the table"): a stake or
            # show of coin, not a transfer. No ledger movement — coins change
            # hands only when a real payee exists. Recorded as a personal
            # event so voicing/initiative see the stake as committed truth
            # instead of confabulating its fate.
            return skip("stake exceeds carried coins", tcs) if player.coins.to_i < spec["amount"].to_i
            execute_tool(resolver, "propose_event", {
              "scope"        => "personal",
              "trigger"      => "coins set out openly",
              "details"      => "#{player.name} set out #{spec['amount']} coins openly#{spec['reason'].to_s.strip.empty? ? '' : " — #{spec['reason']}"}.",
              "participants" => [ { "character_id" => player.id, "role" => "actor" } ]
            }, into: tcs)
          end
        when "buy"
          return skip("buy without item_id/to_id", tcs) unless spec["item_id"] && spec["to_id"]
          execute_tool(resolver, "buy_item", { "item_id" => spec["item_id"], "merchant_id" => spec["to_id"], "buyer_id" => player.id }, into: tcs)
        when "sell"
          return skip("sell without item_id/to_id", tcs) unless spec["item_id"] && spec["to_id"]
          execute_tool(resolver, "sell_item", { "item_id" => spec["item_id"], "merchant_id" => spec["to_id"], "seller_id" => player.id }, into: tcs)
        when "open"
          return skip("open without item_id", tcs) unless spec["item_id"]
          execute_tool(resolver, "open_container", { "item_id" => spec["item_id"], "by_character_id" => player.id }, into: tcs)
        else
          return redispatch("unknown inventory action #{spec['action'].inspect}", tcs)
        end

        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      private

      def decide(context, input, step, scene, player)
        user = JSON.pretty_generate(
          "player_input"       => input,
          "intent"             => step&.intent,
          "player"             => { "id" => player.id, "name" => player.name },
          "present_items"      => Array(scene && scene["present_items"]),
          "present_characters" => Array(scene && scene["present_characters"]).map { |c| { "id" => c["id"], "name" => c["name"], "subrole" => c["subrole"] } }
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_inventory) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner inventory] decide failed: #{e.class}: #{e.message}" }
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
