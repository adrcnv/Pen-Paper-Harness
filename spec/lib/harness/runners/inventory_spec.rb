require "rails_helper"

RSpec.describe Harness::Runners::Inventory do
  let(:tavern)  { Location.create!(name: "Tavern") }
  let!(:player) { Player.create!(name: "Hero", location: tavern, coins: 20) }
  let!(:barkeep) { Npc.create!(name: "Tomas", subrole: "barkeep", location: tavern, coins: 5) }
  let!(:locket)  { Item.create!(name: "smooth locket", location: tavern) }
  let(:step)    { Harness::Dispatcher::Step.new(runner: "inventory", intent: "take it", args: {}) }

  INV_ACT_MARK  = "player's own hands"
  INV_BIND_MARK = "bind the thing"

  # One stub for the step: the act judge answers `act`, the binder `bind`
  # (a hash, or a block called at bind time). `seen` collects every prompt.
  def inv_ctx(act:, bind: nil, seen: [], extras: [], last_speakers: [])
    stub = StubLLM.new do |full|
      seen << full
      if full.include?(INV_ACT_MARK)     then act.to_json
      elsif full.include?(INV_BIND_MARK) then (bind.respond_to?(:call) ? bind.call : bind).to_json
      else "{}"
      end
    end
    ctx = Harness::Turn::Context.new(player_location: tavern, llm_nuance: stub, game_time: 100)
    if extras.any? || last_speakers.any?
      ctx.active_scene = Harness::Scene::Active.new(location: tavern, snapshot: nil, narrations: [], extras: extras, last_speakers: last_speakers)
    end
    ctx
  end

  def act(kind, with_id: nil, amount: nil) = { "reasoning" => "judged", "act" => kind, "with_id" => with_id, "amount" => amount }
  def bound(id, *for_ids) = { "reasoning" => "bound", "item_id" => id, "for_item_ids" => for_ids }
  let(:implicit_step) { Harness::Dispatcher::Step.new(runner: "inventory", intent: nil, args: { "implicit" => true }) }
  def run!(ctx, input) = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: input, step: step)
  def payload_of(prompt)
    body = prompt.split("INPUT:\n", 2).last
    JSON.parse(body[0..body.rindex("}")])
  end
  def prompts(seen, mark) = seen.select { |p| p.include?(mark) }
  # A refusal of the player's hands toward someone present is an answer: an
  # ok outcome carrying a hands_refused record with the player's line.
  def refused_line(outcome)
    expect(outcome.status).to eq(:ok)
    outcome.tool_calls.find { |t| t["name"] == "hands_refused" }&.dig("result", "line")
  end

  describe "the act judge" do
    it "sees the player's words, purse, carried names and debts, what lies here with sellers and prices, who is here by id with their trade, and the turn's receipts — never the painted extras" do
      Item.create!(name: "dark ale", subrole: "drink", location: tavern, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => barkeep.id })
      Item.create!(name: "trowel", character: player)
      seen = []
      ctx = inv_ctx(act: act("none"), seen: seen, extras: [ "a boy by the hearth" ], last_speakers: [ barkeep.id ])
      Obligation.create!(debtor: barkeep, creditor: player, kind: "coins", amount: 1, terms: "for the cider", game_time: 90)
      ctx.turn_transcript = Harness::Turn::Transcript.new(input: "hand me the knife")
      ctx.turn_transcript.record_tool_calls([ { "name" => "give_item", "args" => { "item_id" => locket.id, "from_id" => barkeep.id, "to_id" => player.id }, "result" => { "item_id" => locket.id, "item_name" => "smooth locket", "from_id" => barkeep.id, "to_id" => player.id } } ])
      run!(ctx, "hand me the knife")
      judged = payload_of(prompts(seen, INV_ACT_MARK).first)
      expect(judged["player_said"]).to eq("hand me the knife")
      expect(judged["you"]).to eq("id" => player.id, "name" => "Hero", "coins" => 20)
      expect(judged["carried"]).to eq([ "trowel" ])
      expect(judged["debts"]).to eq([ "Tomas owes you 1 coins — for the cider" ])
      expect(judged["here"]).to include({ "name" => "smooth locket" }, a_hash_including("name" => "dark ale", "for_sale_by" => "Tomas"))
      expect(judged["here"].find { |h| h["name"] == "dark ale" }["price"]).to be_a(Integer)
      expect(judged["present"]).to eq([ { "id" => barkeep.id, "name" => "Tomas", "trade" => "barkeep" } ])
      expect(judged).not_to have_key("figures")
      expect(judged["spoke_last_turn"]).to eq([ "Tomas" ])
      expect(judged["this_turn"]).to eq([ "Tomas hands you the smooth locket." ])
    end

    it "none: asking someone else to hand over, pay or take is their act — the step is skipped with no line and no call" do
      trowel = Item.create!(name: "trowel", character: player)
      seen = []
      outcome = run!(inv_ctx(act: act("none"), seen: seen), "\"Well? Hand me the knife then, Ragnar.\" Hold hand out and wait for him to actually give it over.")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to be_nil
      expect(outcome.tool_calls).to be_empty
      expect(prompts(seen, INV_BIND_MARK)).to be_empty
      expect(trowel.reload.character_id).to eq(player.id)
    end

    it "runs at zero temperature with thinking off; reasoning first in both grammars; every field the prompts name is in the grammar" do
      seen = []
      ctx = inv_ctx(act: act("pickup"), bind: bound(locket.id), seen: seen)
      run!(ctx, "take the locket")
      llm = ctx.llm_nuance
      expect(llm.sampling_calls).to all(eq(temperature: 0, thinking: false, max_tokens: Harness::Runners::Base::JUDGE_MAX_TOKENS))
      expect(llm.sampling_calls.size).to eq(2)
      { described_class::ACT_PROMPT_PATH => described_class::ACT_SCHEMA, described_class::BIND_PROMPT_PATH => described_class::BIND_SCHEMA }.each do |path, schema|
        expect(schema["properties"].keys.first).to eq("reasoning")
        expect(schema["required"]).to eq(schema["properties"].keys)
        named = File.read(path).split("Output:", 2).last.scan(/"(\w+)":/).flatten.uniq
        expect(named.sort).to eq(schema["properties"].keys.sort), "#{File.basename(path)} names #{named.inspect}"
      end
      output = File.read(described_class::ACT_PROMPT_PATH).split("Output:", 2).last
      expect(output.scan(/"act": ((?:"\w+"\|?)+)/).flatten.first.scan(/\w+/).sort).to eq(described_class::ACTS.sort)
    end

    it "an unparseable act answer redispatches" do
      ctx = Harness::Turn::Context.new(player_location: tavern, llm_nuance: StubLLM.new { "not json" }, game_time: 100)
      expect(run!(ctx, "take the locket").status).to eq(:redispatch)
    end
  end

  describe "the binder sees only the list the act can be about, and an id off it binds nothing" do
    it "pickup binds among the things lying here, never the player's own" do
      trowel = Item.create!(name: "trowel", character: player)
      seen = []
      outcome = run!(inv_ctx(act: act("pickup"), bind: bound(locket.id), seen: seen), "take the locket")
      expect(outcome.status).to eq(:ok)
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "pickup" ])
      expect(locket.reload.character_id).to eq(player.id)
      judged = payload_of(prompts(seen, INV_BIND_MARK).first)
      expect(judged["act"]).to eq("pickup")
      expect(judged["things"].map { |t| t["id"] }).to eq([ locket.id ])
      expect(judged["things"].map { |t| t["id"] }).not_to include(trowel.id)
    end

    it "a thing that exists only in fiction binds nothing — the dead end voices itself" do
      outcome = run!(inv_ctx(act: act("pickup"), bind: bound(nil)), "take the ale")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("There's nothing like that here to take.")
    end

    it "with the chain shirt already gone, 'hand the chain shirt' binds nothing — the scimitar stays (an id off the list is refused, not substituted)" do
      scimitar = Item.create!(name: "ancestral scimitar", character: player)
      outcome = run!(inv_ctx(act: act("give", with_id: barkeep.id), bind: bound(nil)), "hand the chain shirt to Tomas")
      expect(refused_line(outcome)).to eq("There's nothing like that to hand over.")
      expect(scimitar.reload.character_id).to eq(player.id)
      outcome = run!(inv_ctx(act: act("give", with_id: barkeep.id), bind: bound(locket.id)), "hand the locket to Tomas")   # not carried: off the list
      expect(refused_line(outcome)).to eq("There's nothing like that to hand over.")
      expect(locket.reload.location_id).to eq(tavern.id)
    end
  end

  describe "give" do
    it "hands a carried thing to the present character the act judge named" do
      shield = Item.create!(name: "studded round shield", character: player)
      seen = []
      outcome = run!(inv_ctx(act: act("give", with_id: barkeep.id), bind: bound(shield.id), seen: seen), "give Tomas my shield")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "give_item" ])
      expect(shield.reload.character_id).to eq(barkeep.id)
      expect(payload_of(prompts(seen, INV_BIND_MARK).first)["things"]).to eq([ { "id" => shield.id, "name" => "studded round shield" } ])
    end

    it "with no one bound to receive it, asks whom — never a guess from the room" do
      shield = Item.create!(name: "studded round shield", character: player)
      outcome = run!(inv_ctx(act: act("give"), bind: bound(shield.id)), "hand it over")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("Hand it to whom?")
      expect(shield.reload.character_id).to eq(player.id)
    end

    it "a with_id that is not here, or the player's own, binds no one" do
      shield = Item.create!(name: "studded round shield", character: player)
      elsewhere = Npc.create!(name: "Far", subrole: "smith", location: Location.create!(name: "Elsewhere"))
      expect(run!(inv_ctx(act: act("give", with_id: elsewhere.id), bind: bound(shield.id)), "give Far the shield").null_line).to eq("Hand it to whom?")
      expect(run!(inv_ctx(act: act("give", with_id: player.id), bind: bound(shield.id)), "give myself the shield").null_line).to eq("Hand it to whom?")
    end

  end

  describe "drop and consume" do
    it "drops a carried thing here" do
      honey = Item.create!(name: "jar of honey", character: player)
      outcome = run!(inv_ctx(act: act("drop"), bind: bound(honey.id)), "set the jar of honey on the bar")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "drop" ])
      expect(honey.reload.location_id).to eq(tavern.id)
    end

    it "eats or drinks a carried provision — the row is used up, the memory gets a line; anything else is refused" do
      fish = Item.create!(name: "hot salt fish", subrole: "meal", character: player, properties: { "tags" => %w[provision food], "modifiers" => [], "effects" => [] })
      outcome = run!(inv_ctx(act: act("consume"), bind: bound(fish.id)), "unwrap the hot salt fish and eat it")
      expect(outcome.status).to eq(:ok)
      expect(outcome.tool_calls.last).to include("name" => "destroy_item")
      expect(outcome.tool_calls.last["result"]).to include("consumed" => "eat", "item_name" => "hot salt fish")
      expect(Item.exists?(fish.id)).to be(false)
      expect(Event.order(:id).last.details["summary"]).to eq("Hero ate the hot salt fish")

      stone = Item.create!(name: "whetstone", character: player)
      outcome = run!(inv_ctx(act: act("consume"), bind: bound(stone.id)), "eat the whetstone")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("That isn't something to eat or drink.")
      expect(Item.exists?(stone.id)).to be(true)
    end
  end

  describe "pay" do
    it "moves coins to the person the act judge named" do
      barkeep.update!(subrole: "porter")   # no trade: coins to them are a gift, not a purchase
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id, amount: 3)), "tip the porter 3 coins")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transfer_coins" ])
      expect(player.reload.coins).to eq(17)
      expect(barkeep.reload.coins).to eq(8)
    end

    it "receive — taking what someone holds out — is that person's act: skipped with no line and no call (hands run 8: 'take the coins from her palm' had come back as a pay to her)" do
      outcome = run!(inv_ctx(act: act("receive", with_id: barkeep.id, amount: 4)), "Take the coins from the barkeep's outstretched palm.")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to be_nil
      expect(outcome.tool_calls).to be_empty
      expect(player.reload.coins).to eq(20)
    end

    it "a stake is coin set out in the open, whoever the judge named: an event, no transfer — the dice move it" do
      outcome = run!(inv_ctx(act: act("stake", with_id: barkeep.id, amount: 2)), "Set two coins on the wall stone.")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "propose_event" ])
      expect(player.reload.coins).to eq(20)
      expect(barkeep.reload.coins).to eq(5)
    end

    it "without a sum, nothing changes hands" do
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id)), "pay")
      expect(refused_line(outcome)).to eq("No sum was settled — nothing changes hands.")
    end

    it "with no one to receive it, records a stake as an event without moving coins; a stake the player cannot cover is refused" do
      outcome = run!(inv_ctx(act: act("pay", amount: 5)), "put 5 coins on the table")
      expect(outcome.status).to eq(:ok)
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "propose_event" ])
      expect(player.reload.coins).to eq(20)
      expect(Event.joins(:event_participants).where(event_participants: { character_id: player.id })).to exist

      outcome = run!(inv_ctx(act: act("pay", amount: 500)), "put 500 coins on the table")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("You don't have that much coin.")
    end

    it "to a seller with a laid table: the binder names the ware the coins are for and it is bought; none named, their coin moves only for a debt or a thing they handed over this turn" do
      mead = Item.create!(name: "honeyed mead", subrole: "drink", location: tavern, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => barkeep.id })
      seen = []
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id, amount: 2), bind: bound(mead.id), seen: seen), "I'll take that honeyed mead — here's your two coins.")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "buy_item" ])
      expect(mead.reload.character_id).to eq(player.id)
      expect(payload_of(prompts(seen, INV_BIND_MARK).first)["things"].map { |t| t["id"] }).to eq([ mead.id ])
    end

    it "to a seller with nothing out at all, coins are refused unless owed or a thing was handed over — the gate is the trade, not a table (hands run 6 t5–t6)" do
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id, amount: 5), bind: bound(nil)), "Here, take this. Now, what will you give me for it?")
      expect(refused_line(outcome)).to eq("Nothing was handed over — you keep your coin.")
      expect(player.reload.coins).to eq(20)

      guard = Npc.create!(name: "Ysme", subrole: "guard", location: tavern, character_class: "commoner")
      outcome = run!(inv_ctx(act: act("pay", with_id: guard.id, amount: 1), bind: bound(nil)), "a coin for your trouble")   # no trade: a gift, not a purchase
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transfer_coins" ])
      expect(player.reload.coins).to eq(19)
    end

    it "a give judged with a coin amount is a pay: the coin moves and settles the debt, the carried thing the coin was for stays (hands run 6 t18)" do
      edith = Npc.create!(name: "Edith Marston", subrole: "commoner", location: tavern, character_class: "commoner", coins: 0)
      fish  = Item.create!(name: "salt fish", subrole: "meal", character: player, properties: { "tags" => %w[provision] })
      Obligation.create!(debtor: player, creditor: edith, kind: "coins", amount: 1, terms: "took salt fish from Edith Marston's table without paying", game_time: 90)
      seen = []
      outcome = run!(inv_ctx(act: act("give", with_id: edith.id, amount: 1), bind: bound(fish.id), seen: seen), "Hand Edith one coin. \"There — for the fish. We're square.\"")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transfer_coins" ])
      expect(player.reload.coins).to eq(19)
      expect(fish.reload.character_id).to eq(player.id)
      expect(Obligation.last.status).to eq("settled")
    end

    it "a buy from a seller with nothing out yet names them and binds nothing; from someone with no trade it is not for sale" do
      outcome = run!(inv_ctx(act: act("buy", with_id: barkeep.id), bind: bound(nil)), "I'll buy a portion of salt, whatever the going rate is")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("Tomas has nothing out.")
      expect(outcome.tool_calls).to be_empty

      guard = Npc.create!(name: "Ysme", subrole: "guard", location: tavern, character_class: "commoner")
      outcome = run!(inv_ctx(act: act("buy", with_id: guard.id), bind: bound(nil)), "sell me your spear")
      expect(outcome.null_line).to eq("That isn't for sale here.")
    end

    it "to a seller with a laid table and nothing bound, their coin moves only for a debt or a thing they handed over this turn" do
      Item.create!(name: "honeyed mead", subrole: "drink", location: tavern, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => barkeep.id })
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id, amount: 2), bind: bound(nil)), "Tomas, two coppers for a handful of barley")
      expect(refused_line(outcome)).to eq("Their goods are on the table — buy, or keep your coin.")
      expect(player.reload.coins).to eq(20)

      given = Item.create!(name: "sour cider", subrole: "drink", character: player)
      ctx = inv_ctx(act: act("pay", with_id: barkeep.id, amount: 1), bind: bound(nil))
      ctx.turn_transcript = Harness::Turn::Transcript.new(input: "I'll take that cider. Hand him 1 coin.")
      ctx.turn_transcript.record_tool_calls([ { "name" => "give_item", "args" => { "item_id" => given.id, "from_id" => barkeep.id, "to_id" => player.id }, "result" => { "item_id" => given.id } } ])
      outcome = run!(ctx, "I'll take that cider. Hand him 1 coin.")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transfer_coins" ])
      expect(player.reload.coins).to eq(19)

      Obligation.create!(debtor: player, creditor: barkeep, kind: "coins", amount: 3, terms: "for the ale", game_time: 90)
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id, amount: 3), bind: bound(nil)), "here's what I owe you")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "transfer_coins" ])
      expect(player.reload.coins).to eq(16)
      expect(Obligation.last.status).to eq("settled")
    end

    it "a refused transfer says so" do
      player.update!(coins: 2)
      Obligation.create!(debtor: player, creditor: barkeep, kind: "coins", amount: 10, terms: "for the room", game_time: 90)
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id, amount: 10)), "pay Tomas 10 coins")
      expect(refused_line(outcome)).to eq("You don't have that much coin.")
    end

    it "a refusal is an answer, not a dead end: the record renders the player's line and tells every judge, in third person, what was tried and why it did not happen" do
      outcome = run!(inv_ctx(act: act("pay", with_id: barkeep.id, amount: 5).merge("reasoning" => "a deposit for a knife"), bind: bound(nil)), "here's a deposit")
      rec = outcome.tool_calls.find { |t| t["name"] == "hands_refused" }
      expect(rec["args"]).to include("act" => "pay", "with_id" => barkeep.id, "amount" => 5)
      expect(rec.dig("result", "fact")).to eq("Nothing changed hands: #{player.name} held out 5 coins to Tomas — Tomas is owed nothing by #{player.name} and has handed nothing over for them; coins to a tradesperson are for goods bought or owed, never in advance (a deposit for a knife).")
      expect(rec.dig("result", "fact")).not_to match(/\byou\b/i)
      expect(outcome.null_line).to be_nil

      ctx = inv_ctx(act: act("none"))
      ctx.turn_transcript = Harness::Turn::Transcript.new(input: "x")
      ctx.turn_transcript.record_tool_calls([ rec ])
      ctx.turn_transcript.null_lines << "There's nothing like that here to take."
      expect(described_class.new.send(:engine_this_turn, ctx, [])).to eq([ rec.dig("result", "fact"), "There's nothing like that here to take." ])
      expect(Harness::Turn::Parts.render_call(rec, ctx, nil)).to eq(kind: :line, text: "Nothing was handed over — you keep your coin.")
    end
  end

  describe "buy, sell, trade" do
    let!(:ale) { Item.create!(name: "dark ale", subrole: "drink", location: tavern, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [], "for_sale" => true, "seller_id" => barkeep.id }) }

    it "buy binds among the seller's wares on the table, with prices, and buys at the engine's price" do
      seen = []
      outcome = run!(inv_ctx(act: act("buy", with_id: barkeep.id), bind: bound(ale.id), seen: seen), "I'll take that ale — here's your coin")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "buy_item" ])
      expect(ale.reload.character_id).to eq(player.id)
      things = payload_of(prompts(seen, INV_BIND_MARK).first)["things"]
      expect(things.map { |t| t["id"] }).to eq([ ale.id ])
      expect(things.first["price"]).to be_a(Integer)
    end

    it "buy with no seller bound, or nothing bound on their table, is not for sale here" do
      expect(run!(inv_ctx(act: act("buy"), bind: bound(ale.id)), "buy it").null_line).to eq("That isn't for sale here.")
      outcome = run!(inv_ctx(act: act("buy", with_id: barkeep.id), bind: bound(nil)), "buy the honey")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("That isn't for sale here.")   # he has wares out, not that one
      expect(run!(inv_ctx(act: act("buy", with_id: barkeep.id), bind: bound(locket.id)), "buy the locket").null_line).to eq("That isn't for sale here.")   # loose, not a ware
    end

    it "sell hands a carried thing to a buyer for coins; a buyer outside the trade refuses honestly" do
      owned = Item.create!(name: "my ale", subrole: "drink", character: player, properties: { "tags" => %w[provision drink], "modifiers" => [], "effects" => [] })
      outcome = run!(inv_ctx(act: act("sell", with_id: barkeep.id), bind: bound(owned.id)), "sell Tomas my ale")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "sell_item" ])
      expect(owned.reload.character_id).not_to eq(player.id)
      expect(run!(inv_ctx(act: act("sell"), bind: bound(owned.id)), "sell it").null_line).to eq("No one here will buy that.")
    end

    it "trade binds the carried thing and their wares, and swaps through trade_items" do
      scimitar = Item.create!(name: "ancestral scimitar", subrole: "scimitar", character: player)
      seen = []
      outcome = run!(inv_ctx(act: act("trade", with_id: barkeep.id), bind: bound(scimitar.id, ale.id), seen: seen), "swap my scimitar for the ale")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "trade_items" ])
      expect(ale.reload.character_id).to eq(player.id)
      expect(scimitar.reload.character_id).to eq(barkeep.id)
      judged = payload_of(prompts(seen, INV_BIND_MARK).first)
      expect(judged["things"].map { |t| t["id"] }).to eq([ scimitar.id ])
      expect(judged["theirs"].map { |t| t["id"] }).to eq([ ale.id ])
    end

    it "a trade for a thing that is not on their table binds nothing" do
      scimitar = Item.create!(name: "ancestral scimitar", subrole: "scimitar", character: player)
      outcome = run!(inv_ctx(act: act("trade", with_id: barkeep.id), bind: bound(scimitar.id, locket.id)), "swap my scimitar for the locket")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("Trade what for what?")
      expect(scimitar.reload.character_id).to eq(player.id)
    end
  end

  describe "shop stock (no seller recorded) sells through whoever the act judge named" do
    let(:shop) { Location.create!(name: "the Smithy", parent: Location.create!(name: "Town", x: 1, y: 1, properties: { "economic_basis" => "farming", "size" => "town", "wealth" => "modest" }), properties: { "shop" => %w[weapons armor], "trade" => "smith" }) }
    let!(:smith) { Npc.create!(name: "Brann", subrole: "smith", location: shop, coins: 500) }
    let!(:ware) { Item.create!(name: "blade", subrole: "longblade", location: shop, properties: { "tags" => %w[weapon edged], "modifiers" => [], "effects" => [], "for_sale" => true }) }

    before { player.update!(location: shop, coins: 200) }

    it "buys from the smith" do
      ctx = Harness::Turn::Context.new(player_location: shop, llm_nuance: StubLLM.new { |full| (full.include?(INV_ACT_MARK) ? act("buy", with_id: smith.id) : bound(ware.id)).to_json }, game_time: 100)
      outcome = run!(ctx, "buy the blade")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "buy_item" ])
      expect(ware.reload.character_id).to eq(player.id)
    end

    it "a patron cannot sell the shop's stock — the tool's refusal is a clean dead end with its own line" do
      patron = Npc.create!(name: "Wat", subrole: "labourer", location: shop)
      ctx = Harness::Turn::Context.new(player_location: shop, llm_nuance: StubLLM.new { |full| (full.include?(INV_ACT_MARK) ? act("buy", with_id: patron.id) : bound(ware.id)).to_json }, game_time: 100)
      outcome = run!(ctx, "buy the blade from Wat")
      expect(refused_line(outcome)).to eq("No one here to sell it.")
      expect(ware.reload.location_id).to eq(shop.id)
    end

    it "sells to the smith" do
      owned = Item.create!(name: "my axe", subrole: "longblade", character: player, properties: { "tags" => %w[weapon], "modifiers" => [], "effects" => [] })
      ctx = Harness::Turn::Context.new(player_location: shop, llm_nuance: StubLLM.new { |full| (full.include?(INV_ACT_MARK) ? act("sell", with_id: smith.id) : bound(owned.id)).to_json }, game_time: 100)
      outcome = run!(ctx, "sell my axe")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "sell_item" ])
      expect(owned.reload.location_id).to eq(shop.id)
    end
  end

  describe "open" do
    let!(:chest) { Harness::Treasure::Chest.place(location: tavern, rarity: "common", rng: Random.new(1)) }

    it "binds among the containers here and opens" do
      allow(Harness::Dice).to receive(:check).and_return(Harness::Dice::Outcome.new(result: "success", roll: 20, against: 10))
      seen = []
      outcome = run!(inv_ctx(act: act("open"), bind: bound(chest.id), seen: seen), "open the chest")
      expect(outcome.tool_calls.map { |t| t["name"] }).to eq([ "open_container" ])
      expect(chest.reload.properties["state"]).to eq("open")
      expect(payload_of(prompts(seen, INV_BIND_MARK).first)["things"].map { |t| t["id"] }).to eq([ chest.id ])
    end

    it "nothing bound is a clean dead end" do
      outcome = run!(inv_ctx(act: act("open"), bind: bound(nil)), "open it")
      expect(outcome.status).to eq(:skipped)
      expect(outcome.null_line).to eq("There's nothing like that here to open.")
    end
  end

  it "a give reads from whoever gave in the receipts — the player's own hand-over, or a character's" do
    ctx  = inv_ctx(act: act("none"))
    ale  = Item.create!(name: "sour ale", character: barkeep)
    call = { "name" => "give_item", "args" => { "item_id" => ale.id, "from_id" => barkeep.id, "to_id" => player.id },
             "result" => { "item_id" => ale.id, "item_name" => "sour ale", "from_id" => barkeep.id, "to_id" => player.id } }
    expect(Harness::Turn::Parts.render_call(call, ctx, nil)[:text]).to eq("Tomas hands you the sour ale.")
    call = { "name" => "give_item", "args" => { "item_id" => ale.id, "from_id" => player.id, "to_id" => barkeep.id },
             "result" => { "item_id" => ale.id, "item_name" => "sour ale", "from_id" => player.id, "to_id" => barkeep.id } }
    expect(Harness::Turn::Parts.render_call(call, ctx, nil)[:text]).to eq("You hand the sour ale to Tomas.")
  end

  it "the same sum does not leave twice in one turn: after a buy receipt of 3 coins to Tomas, a second step judged 'pay Tomas 3' moves nothing (hands run 10 t22: six coins for a three-coin cloak)" do
    ctx = inv_ctx(act: act("pay", with_id: barkeep.id, amount: 3))
    ctx.turn_transcript = Harness::Turn::Transcript.new(input: "Count out three coins and hand them to Tomas, taking the cloak.")
    ctx.turn_transcript.record_tool_calls([ { "name" => "buy_item", "args" => { "item_id" => 99, "merchant_id" => barkeep.id, "buyer_id" => player.id },
                                             "result" => { "item_id" => 99, "item_name" => "wool cloak", "buyer_id" => player.id, "merchant_id" => barkeep.id, "price" => 3 } } ])
    outcome = run!(ctx, "Count out three coins and hand them to Tomas, taking the cloak.")
    expect(outcome.status).to eq(:skipped)
    expect(outcome.tool_calls.map { |t| t["name"] }).not_to include("transfer_coins")
    expect(player.reload.coins).to eq(20)
  end

  describe "the implicit hands step (a talk turn the planner wrote no inventory step for)" do
    it "is an ordinary ok when the hands are still — no stall, no null line, nothing unresolved" do
      ctx = inv_ctx(act: act("none"))
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "'Fine weather.'", step: implicit_step)
      expect(outcome.status).to eq(:ok)
      expect(outcome.null_line).to be_nil
      expect(outcome.tool_calls).to eq([])
    end

    it "still hands things over when the words did (hands run 9 t18: 'Take it now' with no hand verb)" do
      knife = Item.create!(name: "small carving knife", character: player)
      ctx = inv_ctx(act: act("give", with_id: barkeep.id), bind: bound(knife.id))
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "'Take it now, owe me two coins.'", step: implicit_step)
      expect(outcome.status).to eq(:ok)
      expect(knife.reload.character_id).to eq(barkeep.id)
    end

    it "is silent when its act binds nothing: 'I'll take the rope' before the rope is set out says nothing to the player (hands run 10 t11)" do
      ctx = inv_ctx(act: act("buy", with_id: barkeep.id))
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "'I'll take the rope. What's your price?'", step: implicit_step)
      expect(outcome.status).to eq(:ok)
      expect(outcome.null_line).to be_nil
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "'I'll take the rope. What's your price?'", step: step)
      expect(outcome.status).to eq(:skipped)   # the planner's own step still says so
    end

    it "fails open on an unreadable judge instead of re-dispatching the turn" do
      ctx = inv_ctx(act: { "garbage" => true })
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "'Hm.'", step: implicit_step)
      expect(outcome.status).to eq(:ok)
      outcome = described_class.new.run(context: ctx, scene: Harness::Tools::QueryScene.build(ctx), input: "'Hm.'", step: step)
      expect(outcome.status).to eq(:redispatch)
    end
  end
end
