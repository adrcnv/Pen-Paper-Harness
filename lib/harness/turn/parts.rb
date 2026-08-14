module Harness
  module Turn
    # Mechanical turn rendering: transcript.tool_calls in, typed display parts
    # out. Each part is { kind:, text: } — the kinds drive per-part styling in
    # the presenter (Render.parts) and NOTHING here calls a model. The law:
    # causal authority = rendering authority. The organ that committed a change
    # gets its change rendered from its own tool result, in tool-call order;
    # no voice describes what another voice did, and nothing describes what
    # didn't happen.
    #
    # Kinds:
    #   :bracket  — the dice scoreboard line (authoritative, from resolve)
    #   :dialogue — an NPC's staged line, verbatim (beat + quote, self-framing)
    #   :card     — arrival card on a scene transition (place, clock, who's here)
    #   :line     — a mechanical outcome sentence ("You take the locket.")
    #   :stock    — fixed non-event lines (silence, stalls, table talk)
    #   :beat     — the initiative NPC's trailing move (appended by the loop)
    #   :combat   — assembled combat-round narration (replaces the whole list)
    #   :fragment — a runner's own delta prose (Base#emit_fragment, verbatim)
    #   :perception — the player's-eyes state prose (loop-appended last;
    #                 display-only — never enters the buffer or LLM payloads)
    module Parts
      # Display gate for non-staged world events (the stake gesture, a spell's
      # committed record): render short personal ones whole, skip long ones
      # whole. Never cut mid-string — truncation is not selection.
      EVENT_LINE_MAX = 220

      module_function

      def compose(transcript:, context:, scene:)
        parts = []
        seen_scene_card = false
        Array(transcript.tool_calls).each do |tc|
          # An inspection turn's whole point is the look itself: render its
          # query_scene result as a mechanical scene card (first one only —
          # later reads in the same chain are runner bookkeeping, not looks).
          if tc["name"] == "query_scene" && !seen_scene_card &&
             Array(transcript.runners_ran).include?("inspection")
            seen_scene_card = true
            card = scene_card(tc["result"], context)
            parts << card if card
            next
          end
          part = render_call(tc, context, scene)
          parts << part if part.is_a?(Hash)
        end
        if transcript.unresolved
          parts << { kind: :stock, text: "Nothing comes of it — #{transcript.unresolved.to_s.strip}." }
        end
        parts.reject { |p| p[:text].to_s.strip.empty? }
      end

      def render_call(tc, context, scene)
        result = tc["result"]
        args   = tc["args"] || {}
        return nil if result.is_a?(Hash) && result["error"]

        case tc["name"]
        when "resolve"          then bracket(tc)
        when "propose_event"    then event_part(args, result)
        when "display_fragment" then fragment_part(args)
        when "display_perception" then perception_part(args)
        when "transition"       then arrival_card(result, context, scene)
        when "travel"           then travel_line(result)
        when "pickup"           then line("You take the #{result['item_name']}.")
        when "drop"             then line("You set down the #{result['item_name']}.")
        when "give_item"        then give_line(args, result)
        when "transfer_coins"   then coins_line(result)
        when "buy_item"         then trade_line(result, "buy")
        when "sell_item"        then trade_line(result, "sell")
        when "open_container"   then open_line(result)
        when "pass_time"        then pass_time_line(result)
        when "propose_location" then discovery_line(args, result, context)
        when "propose_item"     then found_line(args, result, context)
        when "start_combat"     then line("⚔ The fight begins.")
        when "conversation_silence" then { kind: :stock, text: "No one reacts." }
        when "meta"             then { kind: :stock, text: "(The moment passes.)" }
        end
      end

      # --- per-tool renderers -------------------------------------------------

      # Same authoritative format the narrator-era composer used; the roll is
      # Ruby's truth, never prose.
      def bracket(tc)
        r = tc["result"]
        return nil unless r.is_a?(Hash) && r["outcome"]
        label = r["ability_name"].to_s.strip
        label = r["stat"].to_s.capitalize if label.empty?
        nums  = (r["roll"] && r["against"]) ? " #{r['roll']} vs #{r['against']}" : ""
        tail  = [ r["outcome"], r["margin"] ].compact.reject { |s| s.to_s.empty? }
        tail << "critical" if r["critical"]
        { kind: :bracket, text: "[#{r['action']} — #{label}#{nums}: #{tail.join(', ')}]" }
      end

      # Staged dialogue renders verbatim (the beat + quote is the voicing
      # organ's own prose). Other committed events show whole when short and
      # personal; anything longer is a record, not display.
      def event_part(args, result)
        details = args["details"].to_s.strip
        return nil if details.empty?
        if result.is_a?(Hash) && result["staged"]
          { kind: :dialogue, text: details }
        elsif args["scope"].to_s == "personal" && details.length <= EVENT_LINE_MAX
          { kind: :line, text: details }
        end
      end

      def arrival_card(result, context, scene)
        dest = result.is_a?(Hash) ? result["moved_to"] : nil
        return nil unless dest.is_a?(Hash) && dest["name"]
        t = context.game_time.to_i
        clock = format("day %d, %02d:%02d (%s)", t / 1440, (t % 1440) / 60, t % 60, ::Harness::Clock.phase(t))
        card = "— #{dest['name']} — #{clock}"
        present = Array(scene&.present_characters).map { |c|
          c.subrole.to_s.strip.empty? ? c.name : "#{c.name} (#{c.subrole})"
        }
        card += "\nPresent: #{present.join(', ')}." if present.any?
        { kind: :card, text: card }
      end

      def give_line(args, result)
        item = result.is_a?(Hash) && result["item_name"] || "item"
        to   = char_name(result.is_a?(Hash) && result["to_id"] || args["to_id"])
        line("You hand the #{item} to #{to}.")
      end

      def coins_line(result)
        return nil unless result.is_a?(Hash) && result["amount"]
        payer_is_player = result["from_id"] == player_id
        other = char_name(payer_is_player ? result["to_id"] : result["from_id"])
        text  = payer_is_player ? "You pay #{other} #{result['amount']} coins." :
                                  "#{other} pays you #{result['amount']} coins."
        if (ob = result["obligation"])
          text += ob["status"] == "settled" ? " The debt is settled." :
                                              " #{ob['remaining']} coins still owed."
        end
        line(text)
      end

      def trade_line(result, verb)
        return nil unless result.is_a?(Hash)
        item  = result["item_name"] || result.dig("item", "name") || "the goods"
        price = result["price"] || result["amount"]
        text  = verb == "buy" ? "You buy the #{item}" : "You sell the #{item}"
        text += " for #{price} coins" if price
        line("#{text}.")
      end

      def open_line(result)
        return nil unless result.is_a?(Hash)
        name = result["item_name"] || result.dig("item", "name") || "container"
        unless result["opened"]
          return line("The #{name} holds shut.")
        end
        contents = Array(result["contents"]).map { |c| c.is_a?(Hash) ? c["name"] : c }.compact
        text = "You open the #{name}"
        text += contents.any? ? " — inside: #{contents.join(', ')}." : ". Empty."
        line(text)
      end

      def pass_time_line(result)
        return nil unless result.is_a?(Hash) && result["duration_minutes"]
        mins = result["duration_minutes"].to_i
        span = mins >= 60 ? "#{(mins / 60.0).round(1).to_s.sub(/\.0$/, '')} hours" : "#{mins} minutes"
        line("Time passes — #{span} (#{result['intent']}).")
      end

      # A place now exists that the player did NOT walk into: they became
      # aware of it. Its authored description is worldbuilding's own prose.
      def discovery_line(args, result, context)
        name = args["name"] || (result.is_a?(Hash) && result["name"])
        return nil unless name
        here = context.player_location&.id
        loc_id = result.is_a?(Hash) ? (result["location_id"] || result["id"]) : nil
        return nil if loc_id && loc_id == here # entered via the chain; the arrival card covers it
        desc = args["description"].to_s.strip
        line(desc.empty? ? "You learn of #{name}." : "You learn of #{name} — #{desc}")
      end

      # An item minted into the player's scene (an environment yield, mostly).
      def found_line(args, result, context)
        return nil unless args["location_id"].nil? || args["location_id"] == context.player_location&.id
        name = args["name"] || (result.is_a?(Hash) && result["name"])
        name ? line("Found: #{name}.") : nil
      end

      # A runner's own delta prose, shipped through the tool-call stream
      # (Base#emit_fragment). Verbatim — the organ that committed the change
      # authored this text; nothing here re-touches it.
      def fragment_part(args)
        text = args["text"].to_s.strip
        text.empty? ? nil : { kind: :fragment, text: text }
      end

      # The eyes' prose, when a transcript is re-composed (replay paths). In
      # a live turn the loop appends both the record and the part itself.
      def perception_part(args)
        text = args["text"].to_s.strip
        text.empty? ? nil : { kind: :perception, text: text }
      end

      # An inter-city journey leg: arrived / stopped short / stumbled onto a
      # place. All fields are the travel tool's own mechanical truth.
      def travel_line(result)
        return nil unless result.is_a?(Hash)
        span = format_minutes(result["minutes"])
        case result["outcome"]
        when "arrived"
          line("The road brings you to #{result.dig('destination', 'name')}#{span ? " — #{span} traveled" : ''}.")
        when "snapped"
          line("You make for #{result.dig('destination', 'name')} — #{span || 'a stretch'} on the road ends at #{result.dig('snapped_to', 'name')}.")
        when "encounter"
          place = result["place"] || {}
          desc  = place["description"].to_s.strip
          line("#{span ? "#{span} down the road, you" : 'On the road, you'} come upon #{place['name']}#{desc.empty? ? '.' : " — #{desc}"}")
        end
      end

      def format_minutes(mins)
        m = mins.to_i
        return nil if m <= 0
        m >= 60 ? "#{(m / 60.0).round(1).to_s.sub(/\.0$/, '')} hours" : "#{m} minutes"
      end

      # The look-around card: the scene as query_scene reported it, dry.
      def scene_card(result, context)
        return nil unless result.is_a?(Hash)
        loc = result.dig("location", "name") || context.player_location&.name
        lines = [ "— #{loc} —" ]
        chars = Array(result["present_characters"]).map { |c|
          c["subrole"].to_s.strip.empty? ? c["name"] : "#{c['name']} (#{c['subrole']})"
        }
        lines << "Present: #{chars.join(', ')}." if chars.any?
        items = Array(result["present_items"]).map { |i| i["name"] }.compact
        lines << "Here: #{items.join(', ')}." if items.any?
        extras = Array(result["present_extras"]).map(&:to_s).reject(&:empty?)
        lines.concat(extras.map { |e| "· #{e}" })
        corpses = Array(result["present_corpses"]).map { |c| c["name"] }.compact
        lines << "Fallen: #{corpses.join(', ')}." if corpses.any?
        desc = result.dig("location", "description").to_s.strip
        lines.insert(1, desc) unless desc.empty?
        { kind: :card, text: lines.join("\n") }
      end

      # --- helpers --------------------------------------------------------------

      def line(text)
        { kind: :line, text: text }
      end

      def player_id
        ::Player.first&.id
      end

      def char_name(id)
        return "them" unless id
        ::Character.find_by(id: id)&.name || "them"
      end
    end
  end
end
