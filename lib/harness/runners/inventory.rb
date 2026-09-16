module Harness
  module Runners
    # The player's hands and purse: pickup / drop / give / pay / buy / sell /
    # trade / consume / open. Two narrow judges: which act, with whom, how
    # many coins (the act judge, on the whole room); then which thing, on
    # the one list that act can be about (the binder). An answer outside its
    # list is refused with a null line, never substituted. The single call
    # this replaces bound six things at once and was patched by word-overlap
    # vetoes and a name-or-trade recipient match; "hand me the knife, Ragnar"
    # still gave the trowel away (hands run 1, t13) and "pay up, Orist" tried
    # to hand him a cider off the table (hands run 5, t16). The direction of
    # a hand-over is the act judge's one job now, and `none` is an answer.
    class Inventory < Base
      ACT_PROMPT_PATH  = Rails.root.join("lib/harness/prompts/runners/inventory.txt")
      BIND_PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/inventory_bind.txt")

      ACTS = %w[pickup drop give pay buy sell trade consume open none].freeze
      # Property order is grammar on the hosted sampler: `reasoning` first,
      # every field required.
      ACT_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "act"       => { "type" => "string", "enum" => ACTS },
          "with_id"   => { "type" => %w[integer null] },
          "figure"    => { "type" => %w[integer null] },
          "amount"    => { "type" => %w[integer null] }
        },
        "required" => %w[reasoning act with_id figure amount],
        "additionalProperties" => false
      }.freeze
      BIND_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning"    => { "type" => "string" },
          "item_id"      => { "type" => %w[integer null] },
          "for_item_ids" => { "type" => "array", "items" => { "type" => "integer" } }
        },
        "required" => %w[reasoning item_id for_item_ids],
        "additionalProperties" => false
      }.freeze
      SAMPLING = { temperature: 0, thinking: false }.freeze

      def run(context:, scene:, input:, step:)
        player = ::Player.first
        return redispatch("no player row") unless player

        act = judge_act(context, scene, input, player)
        return redispatch("inventory act unparseable") if act.nil?
        kind = act["act"].to_s
        return redispatch("unknown inventory act #{kind.inspect}") unless ACTS.include?(kind)

        resolver = resolver_for(context)
        tcs = []
        @logger.info { "[Runner inventory] #{kind}#{act['with_id'] ? " with ##{act['with_id']}" : ''}#{act['figure'] ? " figure #{act['figure']}" : ''}#{act['amount'] ? " #{act['amount']} coins" : ''} (#{act['reasoning']})" }
        # The player's hands do nothing here: what they said asks someone
        # else to act, and that person's own line and hands answer it.
        return skip("the player's hands do nothing: #{act['reasoning']}", tcs) if kind == "none"

        with = counterparty(act, resolver, context, scene, player, tcs)

        case kind
        when "pickup"
          thing = bind(context, input, kind, things_here(scene, player))
          return skip("pickup: nothing bound", tcs, null_line: "There's nothing like that here to take.") unless thing
          _, ok = execute_tool(resolver, "pickup", { "item_id" => thing.id, "by_character_id" => player.id }, into: tcs)
          return skip("pickup refused", tcs, null_line: "You can't get at that.") unless ok
        when "open"
          thing = bind(context, input, kind, containers_here(scene, player))
          return skip("open: nothing bound", tcs, null_line: "There's nothing like that here to open.") unless thing
          execute_tool(resolver, "open_container", { "item_id" => thing.id, "by_character_id" => player.id }, into: tcs)
        when "drop"
          thing = bind(context, input, kind, player.items.to_a)
          return skip("drop: nothing bound", tcs, null_line: "You aren't carrying anything like that.") unless thing
          execute_tool(resolver, "drop", { "item_id" => thing.id, "by_character_id" => player.id }, into: tcs)
        when "consume"
          thing = bind(context, input, kind, player.items.to_a)
          return skip("consume: nothing bound", tcs, null_line: "You aren't carrying anything like that to eat or drink.") unless thing
          tags = Array(thing.properties.is_a?(::Hash) ? thing.properties["tags"] : nil)
          return skip("consume: not a provision", tcs, null_line: "That isn't something to eat or drink.") unless tags.include?("provision")
          verb = tags.include?("drink") ? "drink" : "eat"
          execute_tool(resolver, "destroy_item", { "item_id" => thing.id, "reason" => "consumed", "consumed" => verb,
                                                   "summary" => "#{player.name} #{verb == 'drink' ? 'drank' : 'ate'} the #{thing.name}" }, into: tcs)
        when "give"
          return skip("give: no one bound to receive it", tcs, null_line: "Hand it to whom?") unless with
          thing = bind(context, input, kind, player.items.to_a)
          return skip("give: nothing bound", tcs, null_line: "There's nothing like that to hand over.") unless thing
          _, ok = execute_tool(resolver, "give_item", { "item_id" => thing.id, "from_id" => player.id, "to_id" => with, "reason" => act["reasoning"] }, into: tcs)
          return skip("give refused", tcs, null_line: "There's nothing like that to hand over.") unless ok
        when "sell"
          return skip("sell: no one bound to buy", tcs, null_line: "No one here will buy that.") unless with
          thing = bind(context, input, kind, player.items.to_a)
          return skip("sell: nothing bound", tcs, null_line: "You aren't carrying anything like that to sell.") unless thing
          _, ok = execute_tool(resolver, "sell_item", { "item_id" => thing.id, "merchant_id" => with, "seller_id" => player.id }, into: tcs)
          return skip("sell refused", tcs, null_line: "No one here will buy that.") unless ok
        when "trade"
          return skip("trade: no one bound to trade with", tcs, null_line: "Trade what for what?") unless with
          theirs = sellers_table(with, player)
          thing, wares = bind(context, input, kind, player.items.to_a, theirs: theirs)
          return skip("trade: nothing bound", tcs, null_line: "Trade what for what?") unless thing && wares.any?
          res, ok = execute_tool(resolver, "trade_items", { "item_id" => thing.id, "for_item_ids" => wares.map(&:id), "with_id" => with, "trader_id" => player.id, "coins" => act["amount"].to_i }, into: tcs)
          return skip("trade refused: #{res['error']}", tcs, null_line: (res["error"].to_s.include?("won't take") ? "They won't take that for it." : "That isn't on the table.")) unless ok
        when "pay", "buy"
          amount = act["amount"].is_a?(::Integer) && act["amount"].positive? ? act["amount"] : nil
          if with
            # Coins to someone with a laid table: the binder names the ware
            # the coins are for, and it is bought at the engine's price;
            # nothing named, their coin moves only for a debt or a thing they
            # handed over this turn — paying for a thing the voice invented
            # was the one leak no prompt closed (items runs 2–6).
            table = sellers_table(with, player)
            ware  = table.any? ? bind(context, input, kind, table) : nil
            if ware
              res, ok = execute_tool(resolver, "buy_item", { "item_id" => ware.id, "merchant_id" => with, "buyer_id" => player.id }, into: tcs)
              return skip("buy refused: #{res['error']}", tcs, null_line: buy_null_line(res["error"])) unless ok
              return Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
            end
            return skip("#{kind}: nothing bound on their table", tcs, null_line: "That isn't for sale here.") if kind == "buy" && amount.nil?
            return skip("pay without amount", tcs, null_line: "No sum was settled — nothing changes hands.") unless amount
            if table.any? && !owes?(player, with) && !handed_this_turn?(with, player, context)
              return skip("pay to a seller with nothing owed and nothing handed over", tcs, null_line: "Their goods are on the table — buy, or keep your coin.")
            end
            res, ok = execute_tool(resolver, "transfer_coins", { "from_id" => player.id, "to_id" => with, "amount" => amount, "reason" => act["reasoning"] }, into: tcs)
            # A refused payment says so (items run 8 t25: 17 coins against 41
            # owed, the error swallowed, the voice took the words as the deed).
            return skip("transfer refused: #{res['error']}", tcs, null_line: (res["error"].to_s.include?("has only") ? "You don't have that much coin." : "Nothing changes hands.")) unless ok
          else
            return skip("#{kind}: no seller bound", tcs, null_line: "That isn't for sale here.") if kind == "buy"
            return skip("pay without amount", tcs, null_line: "No sum was settled — nothing changes hands.") unless amount
            # No one to receive it ("put 5 coins on the table"): a stake or a
            # show of coin, not a transfer. Recorded as a personal event so
            # voicing and initiative see the stake as committed truth.
            return skip("stake exceeds carried coins", tcs, null_line: "You don't have that much coin.") if player.coins.to_i < amount
            execute_tool(resolver, "propose_event", {
              "scope"        => "personal",
              "trigger"      => "coins set out openly",
              "details"      => "#{player.name} set out #{amount} coins openly — #{act['reasoning']}.",
              "participants" => [ { "character_id" => player.id, "role" => "actor" } ]
            }, into: tcs)
          end
        end

        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      private

      # THE ACT JUDGE: which act, with whom, how many coins — on the room as
      # it stands, the player's words, and the turn's receipts so far.
      def judge_act(context, scene, input, player)
        payload = {
          "player_said" => input,
          "you"         => { "id" => player.id, "name" => player.name, "coins" => player.coins.to_i },
          "carried"     => player.items.map(&:name),
          "debts"       => ::Obligation.outstanding.involving(player.id).order(id: :desc).limit(4).map { |o| o.line_for(player.id, now: context.game_time) }.reverse,
          "here"        => things_here(scene, player).map { |i| here_entry(i, scene) } + containers_here(scene, player).map { |i| { "name" => i.name, "container" => true } },
          "present"     => Array(scene && scene["present_characters"]).map { |c| { "id" => c["id"], "name" => c["name"], "trade" => c["subrole"] }.compact },
          "figures"     => Array(scene && scene["present_extras"]).each_with_index.map { |d, i| { "index" => i, "looks" => d } },
          "talking_to"  => talking_to(context, scene),
          "this_turn"   => receipts_this_turn(context, [])
        }.compact
        raw = ::Harness::CostTracker.in_subsystem(:runner_inventory) do
          llm(context).complete(system: act_prompt, user: "INPUT:\n#{JSON.pretty_generate(payload)}", schema: ACT_SCHEMA, **SAMPLING)
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner inventory] act judge failed: #{e.class}: #{e.message}" }
        nil
      end

      # THE BINDER: which of these things — on the one list the act can be
      # about. An id outside the list is nothing bound. For a trade, returns
      # [the carried thing, their wares taken].
      def bind(context, input, kind, things, theirs: nil)
        return (theirs ? [ nil, [] ] : nil) if things.empty?
        payload = { "player_said" => input, "act" => kind, "things" => things.map { |i| bind_entry(i) } }
        payload["theirs"] = theirs.map { |i| bind_entry(i) } if theirs
        raw = ::Harness::CostTracker.in_subsystem(:runner_inventory) do
          llm(context).complete(system: bind_prompt, user: "INPUT:\n#{JSON.pretty_generate(payload)}", schema: BIND_SCHEMA, **SAMPLING)
        end
        ans = parse_emit(raw) || {}
        thing = things.find { |i| i.id == ans["item_id"] }
        @logger.info { "[Runner inventory] bind #{kind}: #{thing ? "##{thing.id} #{thing.name}" : 'nothing'} (#{ans['reasoning']})" }
        return thing unless theirs
        wares = Array(ans["for_item_ids"]).filter_map { |id| theirs.find { |i| i.id == id } }
        [ thing, wares ]
      rescue StandardError => e
        @logger.warn { "[Runner inventory] binder failed: #{e.class}: #{e.message}" }
        theirs ? [ nil, [] ] : nil
      end

      # Who the act is with: a present id the judge named, or a painted
      # figure by index — made real first, as speech would make them, with
      # the thing painted on them laid on their table.
      def counterparty(act, resolver, context, scene, player, tcs)
        present = Array(scene && scene["present_characters"]).map { |c| c["id"] }
        return act["with_id"] if act["with_id"].is_a?(::Integer) && present.include?(act["with_id"]) && act["with_id"] != player.id
        return nil unless act["figure"].is_a?(::Integer)
        promote_extra(resolver, context, scene, act["figure"], into: tcs, cache: {})
      end

      def things_here(scene, player)
        ids = Array(scene && scene["present_items"]).reject { |i| i["container"] }.map { |i| i["id"] }
        ::Item.where(id: ids).to_a
      end

      def containers_here(scene, player)
        ids = Array(scene && scene["present_items"]).select { |i| i["container"] }.map { |i| i["id"] }
        ::Item.where(id: ids).to_a
      end

      def here_entry(item, scene)
        props = item.properties.is_a?(::Hash) ? item.properties : {}
        entry = { "name" => item.name }
        if props["for_sale"]
          seller = props["seller_id"] && Array(scene && scene["present_characters"]).find { |c| c["id"] == props["seller_id"] }
          entry["for_sale_by"] = seller ? seller["name"] : "the house"
          entry["price"] = ::Harness::Tools::QueryScene.shop_price(item, item.location) if item.location
        end
        entry
      end

      def bind_entry(item)
        props = item.properties.is_a?(::Hash) ? item.properties : {}
        entry = { "id" => item.id, "name" => item.name }
        entry["price"] = ::Harness::Tools::QueryScene.shop_price(item, item.location) if props["for_sale"] && item.location
        entry
      end

      # Wares for sale here under this seller's name, plus the house's own
      # stock (no seller recorded), which its staff sell.
      def sellers_table(seller_id, player)
        loc_id = player.location_id
        return [] unless loc_id
        ::Item.where(location_id: loc_id).select { |i|
          props = i.properties.is_a?(::Hash) ? i.properties : {}
          props["for_sale"] && (props["seller_id"] ? props["seller_id"] == seller_id.to_i : true)
        }
      end

      def owes?(player, to_id)
        ::Obligation.open_now.exists?(kind: "coins", debtor_id: player.id, creditor_id: to_id.to_i)
      end

      # They put something into the player's hands this turn (the act judge
      # on their own line): coin for it is a plain payment.
      def handed_this_turn?(from_id, player, context)
        Array(context.turn_transcript&.tool_calls).any? do |tc|
          tc["name"] == "give_item" && !(tc["result"].is_a?(::Hash) && tc["result"]["error"]) &&
            tc.dig("args", "from_id") == from_id.to_i && tc.dig("args", "to_id") == player.id
        end
      end

      def buy_null_line(error)
        e = error.to_s
        return "No one here to sell it." if e.include?("does not keep this stall")
        return "You can't afford it." if e.include?("costs")
        "That isn't for sale here."
      end

      def talking_to(context, scene)
        ids = Array(context.active_scene&.last_speakers)
        return nil if ids.empty?
        Array(scene && scene["present_characters"]).select { |c| ids.include?(c["id"]) }.map { |c| c["name"] }.presence
      end

      def act_prompt  = (@act_prompt  ||= File.read(ACT_PROMPT_PATH))
      def bind_prompt = (@bind_prompt ||= File.read(BIND_PROMPT_PATH))
    end
  end
end
