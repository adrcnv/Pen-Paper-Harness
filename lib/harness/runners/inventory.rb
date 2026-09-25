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

      # `stake` and `receive` are in the list so the judge has a place to put
      # what it sees: asked "take the coins from her outstretched palm" it
      # wrote "Birger takes 4 coins from Gunnhild's hand" and answered pay
      # (9 of 9 on replay, whatever the debts said), "take the knife from
      # Olaf's hand" came back pickup, and coins set out for a wager came
      # back as a pay to the other player — it read each rightly and had no
      # act to file it under (hands run 8). Neither moves anything here.
      ACTS = %w[pickup drop give pay buy stake sell trade consume open receive none].freeze
      # Property order is grammar on the hosted sampler: `reasoning` first,
      # every field required.
      ACT_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "act"       => { "type" => "string", "enum" => ACTS },
          "with_id"   => { "type" => %w[integer null] },
          "amount"    => { "type" => %w[integer null] }
        },
        "required" => %w[reasoning act with_id amount],
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

      # The implicit hands step (a talk turn the planner wrote no inventory
      # step for) acts when it can and says nothing when it cannot: no null
      # line, nothing unresolved, no re-dispatch. "I'll take the rope — what's
      # your price?" judged a buy before the rope was set out in the same
      # turn's talk, and the stall notice reached the player (hands run 10
      # t11). The notices belong to steps the player's words planned.
      def run(context:, scene:, input:, step:)
        outcome = perform(context: context, scene: scene, input: input, step: step)
        return outcome unless step&.args&.dig("implicit") && (outcome.skipped? || outcome.redispatch?)
        @logger.info { "[Runner inventory] implicit step: #{outcome.note} — silent" }
        Outcome.new(tool_calls: outcome.tool_calls, scene_dirty: false, status: :ok, note: "implicit hands step: #{outcome.note}")
      end

      def perform(context:, scene:, input:, step:)
        player = ::Player.first
        return redispatch("no player row") unless player

        act = judge_act(context, scene, input, player)
        return redispatch("inventory act unparseable") if act.nil?
        kind = act["act"].to_s
        return redispatch("unknown inventory act #{kind.inspect}") unless ACTS.include?(kind)
        # A give with a sum is coins: "Hand Edith one coin" was judged give,
        # amount 1, three times of three (hands run 6, t18), and the binder
        # then handed over the fish the coin was for. Amount belongs to pay.
        kind = "pay" if kind == "give" && act["amount"].is_a?(::Integer) && act["amount"].positive?

        resolver = resolver_for(context)
        tcs = []
        @logger.info { "[Runner inventory] #{kind}#{act['with_id'] ? " with ##{act['with_id']}" : ''}#{act['amount'] ? " #{act['amount']} coins" : ''} (#{act['reasoning']})" }
        # The player's hands do nothing here: what they said asks someone
        # else to act, and that person's own line and hands answer it.
        return skip("the player's hands do nothing: #{act['reasoning']}", tcs) if %w[none receive].include?(kind)
        # A stake names no recipient: the dice move it (the wager's verdict),
        # and until then it is coin set out in the open.
        act = act.merge("with_id" => nil) and kind = "pay" if kind == "stake"

        with = counterparty(act, scene, player)

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
          return refused("give: nothing bound", tcs, player, with, kind, act, "There's nothing like that to hand over.", "#{player.name} carries no such thing") unless thing
          res, ok = execute_tool(resolver, "give_item", { "item_id" => thing.id, "from_id" => player.id, "to_id" => with, "reason" => act["reasoning"] }, into: tcs)
          return refused("give refused: #{res['error']}", tcs, player, with, kind, act, "There's nothing like that to hand over.", "the #{thing.name} could not change hands (#{res['error']})", thing: thing) unless ok
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
              return refused("buy refused: #{res['error']}", tcs, player, with, "buy", act, buy_null_line(res["error"]), "#{player.name} cannot buy the #{ware.name} (#{res['error']})", amount: amount) unless ok
              return Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
            end
            if kind == "buy" && amount.nil?
              # A seller with nothing out yet: their own line is the answer
              # (a quote, a "what portion?"); the thing lands when they hand
              # it over. Only someone with no trade has nothing to sell.
              bare = table.empty? && seller?(with, context, table)
              return skip("buy: nothing bound on their table", tcs, null_line: bare ? "#{seller_name(with)} has nothing out." : "That isn't for sale here.")
            end
            return refused("pay without amount", tcs, player, with, kind, act, "No sum was settled — nothing changes hands.", "no sum was named") unless amount
            return skip("already paid #{amount} to ##{with} this turn", tcs, null_line: "Those coins already went over.") if paid_this_turn?(with, amount, player, context)
            # Coins to a seller are for goods: refused when none were handed
            # over this turn and none are owed. Keyed on the trade, not on a
            # table — the laid table is gone, and keyed on it three coins went
            # for salt that never landed and five to a salt worker who said
            # no (hands run 6, t5–t6).
            if seller?(with, context, table) && !owes?(player, with) && !handed_this_turn?(with, player, context)
              return refused("pay to a seller with nothing owed and nothing handed over", tcs, player, with, kind, act,
                             table.any? ? "Their goods are on the table — buy, or keep your coin." : "Nothing was handed over — you keep your coin.",
                             "#{seller_name(with)} is owed nothing by #{player.name} and has handed nothing over for them; coins to a tradesperson are for goods bought or owed, never in advance", amount: amount)
            end
            res, ok = execute_tool(resolver, "transfer_coins", { "from_id" => player.id, "to_id" => with, "amount" => amount, "reason" => act["reasoning"] }, into: tcs)
            # A refused payment says so (items run 8 t25: 17 coins against 41
            # owed, the error swallowed, the voice took the words as the deed).
            unless ok
              short = res["error"].to_s.include?("has only")
              return refused("transfer refused: #{res['error']}", tcs, player, with, kind, act, short ? "You don't have that much coin." : "Nothing changes hands.",
                             short ? "#{player.name} has not got #{amount} coins" : "the coins could not change hands (#{res['error']})", amount: amount)
            end
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

      # A refusal of the player's own hands toward someone present is an
      # ANSWER, not a dead end: the world said no and says why. The record
      # renders the player's line in causal order like any receipt (no null
      # line for a sibling to swallow, no out-of-character notice) and
      # carries the fact in third person, with the act judge's reading of
      # what the player meant, for every judge that reads the turn from a
      # character's seat (deeds-3 t5: the smith's payload held only "you keep
      # your coin", read as the smith keeping it — he pocketed the deposit in
      # prose while the coins never moved).
      def refused(note, tcs, player, with, kind, act, line, why, amount: nil, thing: nil)
        name = ::Character.find_by(id: with)&.name || "them"
        did  = case kind
               when "give"  then "held out #{thing ? "the #{thing.name}" : 'a thing'} to #{name}"
               when "buy"   then amount ? "held out #{amount} coins to #{name}" : "tried to buy from #{name}"
               else              "held out #{amount || 'some'} coins to #{name}"
               end
        fact = "Nothing changed hands: #{player.name} #{did} — #{why} (#{act['reasoning']})."
        tcs << tool_call("hands_refused", { "act" => kind, "with_id" => with, "amount" => amount, "item_id" => thing&.id }.compact,
                         { "refused" => note, "line" => line, "fact" => fact })
        @logger.info { "[Runner inventory] refused: #{note}" }
        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      # THE ACT JUDGE: which act, with whom, how many coins — on the room as
      # it stands, the player's words, and the turn's receipts so far.
      def judge_act(context, scene, input, player)
        payload = {
          "player_said" => input,
          "you"         => { "id" => player.id, "name" => player.name, "coins" => player.coins.to_i },
          "carried"     => player.items.map(&:name),
          "debts"       => ::Obligation.outstanding.involving(player.id).order(id: :desc).limit(4).map { |o| o.line_for(player.id, now: context.game_time) }.reverse,
          "here"        => things_here(scene, player).map { |i| here_entry(i, scene) } + containers_here(scene, player).map { |i| { "name" => i.name, "container" => true } },
          "present"     => present_rows(scene),
          "spoke_last_turn" => talking_to(context, scene),
          "this_turn"   => receipts_this_turn(context, [])
        }.compact
        raw = ::Harness::CostTracker.in_subsystem(:runner_inventory) do
          llm(context).complete(system: act_prompt, user: "INPUT:\n#{JSON.pretty_generate(payload)}", schema: ACT_SCHEMA, max_tokens: JUDGE_MAX_TOKENS, **SAMPLING)
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
          llm(context).complete(system: bind_prompt, user: "INPUT:\n#{JSON.pretty_generate(payload)}", schema: BIND_SCHEMA, max_tokens: JUDGE_MAX_TOKENS, **SAMPLING)
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

      # Who the act is with: a present id the judge named, or no one.
      def counterparty(act, scene, player)
        present = Array(scene && scene["present_characters"]).map { |c| c["id"] }
        return act["with_id"] if act["with_id"].is_a?(::Integer) && present.include?(act["with_id"]) && act["with_id"] != player.id
        nil
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

      # The same sum does not leave the player twice in one turn: the planner
      # cut "count out three coins … taking the cloak" into two hands steps,
      # the buy took the three, and the take step — judged a payment again,
      # the buy receipt in view — took three more (hands run 10 t22). A
      # receipt of this sum to this person this turn ends it.
      def paid_this_turn?(to_id, amount, player, context)
        Array(context.turn_transcript&.tool_calls).any? do |tc|
          next false if tc["result"].is_a?(::Hash) && tc["result"]["error"]
          case tc["name"]
          when "buy_item"       then tc.dig("result", "merchant_id") == to_id.to_i && tc.dig("result", "buyer_id") == player.id && tc.dig("result", "price") == amount
          when "transfer_coins" then tc.dig("args", "from_id") == player.id && tc.dig("args", "to_id") == to_id.to_i && tc.dig("args", "amount") == amount
          else false
          end
        end
      end

      # They put something into the player's hands this turn (the act judge
      # on their own line): coin for it is a plain payment.
      def handed_this_turn?(from_id, player, context)
        Array(context.turn_transcript&.tool_calls).any? do |tc|
          tc["name"] == "give_item" && !(tc["result"].is_a?(::Hash) && tc["result"]["error"]) &&
            tc.dig("args", "from_id") == from_id.to_i && tc.dig("args", "to_id") == player.id
        end
      end

      # Someone with wares out, or a trade that brings things out.
      def seller?(id, context, table)
        return true if table.any?
        npc = ::Npc.find_by(id: id)
        npc.present? && ::Harness::Items::Offers.categories_for(npc, context.player_location).any?
      end

      def seller_name(id)
        ::Npc.find_by(id: id)&.name.to_s.split.first
      end

      def buy_null_line(error)
        e = error.to_s
        return "No one here to sell it." if e.include?("does not keep this stall")
        return "You can't afford it." if e.include?("costs")
        "That isn't for sale here."
      end

      # Who is here, with how they look: "grandmother" is a look, not a name
      # (run 8 t25 bound her wager to a labourer; the addressee judge got
      # looks first).
      def present_rows(scene)
        rows  = Array(scene && scene["present_characters"])
        looks = looks_for(rows.map { |c| c["id"] })
        rows.map { |c| { "id" => c["id"], "name" => c["name"], "trade" => c["subrole"], "looks" => looks[c["id"]] }.compact }
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
