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

        case spec["action"]
        when "pickup"
          return redispatch("pickup without item_id", tcs) unless spec["item_id"]
          execute_tool(resolver, "pickup", { "item_id" => spec["item_id"], "by_character_id" => player.id }, into: tcs)
        when "drop"
          return redispatch("drop without item_id", tcs) unless spec["item_id"]
          execute_tool(resolver, "drop", { "item_id" => spec["item_id"], "by_character_id" => player.id }, into: tcs)
        when "give"
          return redispatch("give without item_id/to_id", tcs) unless spec["item_id"] && spec["to_id"]
          execute_tool(resolver, "give_item", { "item_id" => spec["item_id"], "from_id" => from, "to_id" => spec["to_id"], "reason" => spec["reason"] }, into: tcs)
        when "transfer_coins"
          return redispatch("transfer without to_id/amount", tcs) unless spec["to_id"] && spec["amount"]
          execute_tool(resolver, "transfer_coins", { "from_id" => from, "to_id" => spec["to_id"], "amount" => spec["amount"], "reason" => spec["reason"] }, into: tcs)
        when "buy"
          return redispatch("buy without item_id/to_id", tcs) unless spec["item_id"] && spec["to_id"]
          execute_tool(resolver, "buy_item", { "item_id" => spec["item_id"], "merchant_id" => spec["to_id"], "buyer_id" => player.id }, into: tcs)
        when "sell"
          return redispatch("sell without item_id/to_id", tcs) unless spec["item_id"] && spec["to_id"]
          execute_tool(resolver, "sell_item", { "item_id" => spec["item_id"], "merchant_id" => spec["to_id"], "seller_id" => player.id }, into: tcs)
        when "open"
          return redispatch("open without item_id", tcs) unless spec["item_id"]
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
