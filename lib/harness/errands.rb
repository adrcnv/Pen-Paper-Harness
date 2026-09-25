require "json"

module Harness
  # ERRANDS — what an NPC owes the player in things, work or coins, carried
  # out by the engine rather than left to the voice (the Beorn loop: a
  # seeded pay-agenda with no hands, promising the same coins every turn).
  # The row is born in Knowledge::Capture when a bargain is struck aloud;
  # this organ binds what the deed is owed IN at that moment (one narrow
  # judge on a structured input) and hands it over when a kept row's debtor
  # stands in the player's scene (a per-turn sweep beside
  # Whereabouts.settle_kept_meets!). Kept-or-broken is decided by
  # Obligation.sweep_dues! from the debtor's standing; the arrival is
  # Whereabouts' errand tier. Nothing here reads prose.
  module Errands
    PROMPT_PATH = Rails.root.join("lib/harness/prompts/deed_bind.txt")
    BIND_SCHEMA = {
      "type" => "object",
      "properties" => {
        "reasoning" => { "type" => "string" },
        "is"        => { "type" => "string", "enum" => %w[thing person work] },
        "item_id"   => { "type" => %w[integer null] },
        "label"     => { "type" => %w[string null] },
        "kind"      => { "anyOf" => [ { "type" => "null" }, { "type" => "string", "enum" => ::Harness::Items::Library::CATEGORIES } ] }
      },
      "required" => %w[reasoning is item_id label kind],
      "additionalProperties" => false
    }.freeze
    WORK = { "is" => "work" }.freeze

    module_function

    # At strike: what the deed is owed in. A thing the debtor carries binds
    # to that row; a thing they have yet to produce keeps its kind, to be
    # minted in their hands at delivery (the door the voice's own hand-overs
    # use); a person binds to their row, or is realized through the one
    # people pipe (NarrativeShift::Realizer: a spoken name kept, a role
    # reference named by the picker, homed at the settlement) so there is
    # someone to bring. Anything else is work.
    def bind(terms:, debtor:, context:, logger: Rails.logger)
      llm = context&.llm_grunt
      return WORK.dup unless llm
      carries = debtor.items.order(:id).map { |i| { "id" => i.id, "name" => i.name } }
      payload = { "you" => { "name" => debtor.name, "trade" => debtor.subrole }.compact, "carries" => carries, "owed" => terms }
      raw = ::Harness::CostTracker.in_subsystem(:deed_bind) do
        llm.complete(system: preamble, user: "INPUT:\n#{JSON.pretty_generate(payload)}",
                     schema: BIND_SCHEMA, max_tokens: 256, temperature: 0, thinking: false)
      end
      out = ::Harness::LLM::JsonResponse.parse(raw)
      out = {} unless out.is_a?(::Hash)
      label   = out["label"].to_s.strip.presence
      subject = WORK.dup
      case out["is"]
      when "thing"
        id   = carries.any? { |c| c["id"] == out["item_id"] } ? out["item_id"] : nil
        kind = ::Harness::Items::Library::CATEGORIES.include?(out["kind"]) ? out["kind"] : nil
        subject = { "is" => "thing", "id" => id, "label" => label, "kind" => kind }.compact if id || (kind && label)
      when "person"
        row   = label && ::Harness::NarrativeShift::Realizer.find_existing(label)
        row ||= label && realize(label, terms, debtor, context, logger)
        subject = { "is" => "person", "id" => row.id, "label" => label } if row && row.id != debtor.id
      end
      logger.info { "[Errands] #{debtor.name} owes #{terms.inspect} → #{subject.inspect} (#{out['reasoning'].to_s[0, 80]})" }
      subject
    rescue ::StandardError => e
      logger.warn { "[Errands] bind failed for #{terms.inspect}: #{e.class}: #{e.message}" }
      WORK.dup
    end

    # The person to be brought, when no row answers to the name: the
    # Realizer mints or links them as it does for anyone named in dialogue
    # (the debtor is the speaker who named them). A claim it refuses — the
    # player's own name, nothing to go on — leaves the deed as work.
    def realize(label, terms, debtor, context, logger)
      role = ::Harness::NarrativeShift::Realizer.proper_name?(label) ? nil : ::Harness::NarrativeShift::Realizer.reference_key(label)
      res  = ::Harness::NarrativeShift::Realizer.run(
        claim: { "name" => label, "subrole" => role, "gist" => "to be brought to the player by #{debtor.name}: #{terms}" }.compact,
        speaker: debtor, context: context, logger: logger
      )
      res && ::Npc.find_by(id: res["character_id"])
    end

    # Per turn, after the scene rebuild: a kept errand whose debtor stands
    # in the player's scene is handed over — a carried or freshly minted
    # thing by give_item, coins by transfer_coins, a person by pinning them
    # to the player's place (they arrive at the next rebuild), work by the
    # row alone — and the row settles. A hand-over that cannot happen (the
    # thing gone, the purse short, the person dead) breaks it. A clocked
    # errand is handed over no earlier than it falls due: kept at the
    # window's opening, the debtor sets out; "by midday" is made good at
    # midday, not the moment the word was given (deeds-2 t10). A
    # condition-due errand, which the clock never rolls, is decided here
    # instead, once a whole day-phase has passed since the word was given
    # (the phase after the one it was struck in is over — "come back later").
    # `present_ids` is the assembled roster; records go on the transcript
    # so Parts renders what changed hands.
    def deliver!(context:, transcript:, present_ids:, logger: Rails.logger)
      player = ::Player.first
      loc    = context.player_location
      return unless player && loc && context.game_time
      here = Array(present_ids).map(&:to_i) - [ player.id ]
      return if here.empty?
      now = context.game_time.to_i
      ::Obligation.errands(player).where(debtor_id: here, status: %w[kept open]).order(:id).each do |ob|
        next if ob.status == "kept" && ob.due_time && ob.due_time > now
        if ob.status == "open"
          next unless ob.due_time.nil? && whole_phase_since?(ob.game_time, now)
          next if ob.kind == "coins" && ob.amount.nil?
          unless ob.keeps?
            ob.update!(status: "broken")
            logger.info { "[Errands] BROKEN ##{ob.id} at the meeting: #{ob.terms} (#{ob.debtor.name} #{ob.stance})" }
            next
          end
          ob.update!(status: "kept")
          logger.info { "[Errands] KEPT ##{ob.id} at the meeting: #{ob.terms} (#{ob.debtor.name} #{ob.stance})" }
        end
        hand_over(ob, player, loc, context, transcript, logger)
      end
    rescue ::StandardError => e
      logger.warn { "[Errands] delivery sweep failed (non-fatal): #{e.class}: #{e.message}" }
    end

    def hand_over(ob, player, loc, context, transcript, logger)
      debtor   = ob.debtor
      resolver = ::Harness::Resolver.new(context: context, logger: logger)
      subject  = ob.subject.is_a?(::Hash) ? ob.subject : {}
      mode     = ob.kind == "coins" ? "coins" : subject["is"].to_s
      now      = context.game_time.to_i
      done =
        case mode
        when "coins"
          if debtor.coins.to_i >= ob.amount.to_i
            res = execute(resolver, transcript, "transfer_coins", { "from_id" => debtor.id, "to_id" => player.id, "amount" => ob.amount, "reason" => "owed: #{ob.terms}" })
            # The tool settles OPEN coins rows itself; this one is kept, so
            # the receipt says so here (Parts' coins line reads it).
            res["obligation"] ||= { "status" => "settled" } if res
            res
          end
        when "thing"
          item = ::Item.find_by(id: subject["id"], character_id: debtor.id)
          item ||= ::Harness::Items::Offers.materialize!(debtor, category: subject["kind"], label: subject["label"], game_time: now, to: debtor) if subject["kind"] && subject["label"]
          item && execute(resolver, transcript, "give_item", { "item_id" => item.id, "from_id" => debtor.id, "to_id" => player.id, "reason" => "owed: #{ob.terms}" })
        when "person"
          fetched = ::Npc.find_by(id: subject["id"])
          if fetched && !::Harness::Scene::Residents.deceased?(fetched)
            ::Harness::Scene::Whereabouts.pin!(fetched, loc, now, logger: logger)
            record(transcript, "errand_kept", ob, "brought" => fetched.name)
            kept_event(ob, player, loc, now)
          end
        else
          record(transcript, "errand_kept", ob)
          kept_event(ob, player, loc, now)
        end
      if done
        ob.update!(status: "settled")
        logger.info { "[Errands] SETTLED ##{ob.id}: #{ob.terms} (#{mode})" }
      else
        ob.update!(status: "broken")
        record(transcript, "errand_broken", ob)
        logger.info { "[Errands] BROKEN ##{ob.id} at the hand-over: #{ob.terms} (#{mode})" }
      end
    end

    def whole_phase_since?(struck_at, now)
      w = ::Harness::Scene::Whereabouts
      w.next_phase_boundary(w.next_phase_boundary(struck_at)) <= now
    end

    def execute(resolver, transcript, name, args)
      call   = ::Harness::LLM::ToolCall.new(name: name, args: args)
      result = resolver.execute(call)
      transcript.record_tool_call(call, result)
      result.is_a?(::Hash) && result["error"] ? nil : result
    end

    def record(transcript, name, ob, extra = {})
      transcript.record_tool_calls([ {
        "name"   => name,
        "args"   => { "obligation_id" => ob.id, "debtor_id" => ob.debtor_id, "terms" => ob.terms }.merge(extra),
        "result" => { "status" => name == "errand_kept" ? "settled" : "broken" }
      } ])
    end

    # give_item and transfer_coins log their own events; work and a fetched
    # person leave this one, so the debtor recalls having kept their word.
    def kept_event(ob, player, loc, now)
      ::Harness::Event::ForwardAppender.append(
        game_time: now, scope: "personal", location: loc,
        details: { "summary" => "#{ob.debtor.name} kept the bargain with #{player.name}: #{ob.terms}" },
        participants: [ { character: ob.debtor, role: "subject" }, { character: player, role: "recipient" } ]
      )
      true
    rescue ::StandardError
      true
    end

    def preamble
      @preamble ||= File.read(PROMPT_PATH)
    end
  end
end
