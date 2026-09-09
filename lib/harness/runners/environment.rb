module Harness
  module Runners
    # The player physically acts on a scene OBJECT or feature that is NOT a
    # character — smash, burn, blast, search, pry, dig, cut, barricade. One
    # structured call classifies the act; Ruby orchestrates the real tools:
    #   - resolve         when the attempt is uncertain (a roll)
    #   - propose_item    when it yields something collectible (anchored here)
    #   - mutate_item     when it reworks a real item into something else
    #   - mutate_location when it persistently alters the place
    # A pure-flavor poke (kick a wall, rattle a stuck gate) emits nothing and
    # lets narration render it. This is the runner the "blast the tree, collect
    # the wood" input had no home for — it used to flail dice → inventory →
    # combat → unresolved.
    #
    # Consequences (item / alteration) are gated on the roll NOT failing, so a
    # botched blast yields no firewood and no lasting damage.
    class Environment < Base
      PROMPT_PATH          = Rails.root.join("lib/harness/prompts/runners/environment.txt")
      FRAGMENT_PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/environment_fragment.txt")

      def run(context:, scene:, input:, step:)
        player = ::Player.first
        return redispatch("no player row") unless player

        spec = decide(context, input, step, player, scene)
        return redispatch("environment emit unparseable") if spec.nil?

        resolver = resolver_for(context)
        tcs      = []
        action   = spec["action"].to_s.strip
        action   = "acts on something in the scene" if action.empty?

        roll_ok = true
        botched = false
        roll    = spec["roll"]
        if roll.is_a?(Hash) && (roll["stat"] || roll["ability_name"])
          res, _ = execute_tool(resolver, "resolve", {
            "actor_id"     => player.id,
            "stat"         => roll["stat"],
            "ability_name" => roll["ability_name"],
            "action"       => action,
            "difficulty"   => roll["difficulty"],
            "time_minutes" => spec["time_minutes"] || 2
          }, into: tcs)
          outcome = res.is_a?(Hash) ? res["outcome"].to_s.downcase : ""
          roll_ok = !outcome.include?("fail")
          botched = outcome == "critical_failure"
        end

        transformed = nil
        destroyed   = nil
        consumed    = nil
        hurt        = nil
        if roll_ok
          spawn_item(resolver, spec["yields_item"], action, player, tcs)
          transformed = transform_item(resolver, spec["transforms_item"], action, player, context, tcs)
          consumed    = transformed&.delete("consumed")
          alter_location(resolver, spec["location_change"], context, tcs)
        elsif botched
          # The emit is declared BEFORE the roll, so location_change is the
          # success-shaped alteration — never commit it on a failure. A
          # critical failure commits the pre-declared botch mark instead, so
          # the damage narration renders is real world-state, not prose-only.
          alter_location(resolver, spec["location_change_on_botch"], context, tcs)
          destroyed = ruin_item(resolver, spec["transforms_item"], action, player, context, tcs)
          hurt      = harm_player(spec["harm_on_botch"], player, tcs)
        end

        # The act's own prose island — rendered only when something was
        # actually committed (a delta exists). A pure-flavor poke that emitted
        # nothing stays blank by ruling.
        if tcs.any?
          rolled = tcs.find { |t| t["name"] == "resolve" }&.dig("result")
          failed = rolled && rolled["outcome"].to_s.include?("fail")
          # Margin words prime ruin prose on plain failures ("decisive"
          # rendered as a destroyed item — run-20260821-132705); a failure
          # carries the bare result plus the positive fact of what survived,
          # so the model has truth to render instead of a vacuum to fill.
          unchanged = if failed && !destroyed && spec["transforms_item"].is_a?(::Hash)
            ::Item.find_by(id: spec["transforms_item"]["item_id"])&.name
          end
          emit_fragment(context, FRAGMENT_PROMPT_PATH, {
            "act"           => action,
            "place"         => context.player_location&.name,
            "outcome"       => (rolled && { "result" => rolled["outcome"], "margin" => (failed ? nil : rolled["margin"]) }.compact),
            "yielded"       => tcs.find { |t| t["name"] == "propose_item" }&.dig("args", "name"),
            "transformed"   => transformed,
            "consumed"      => consumed,
            "destroyed"     => destroyed,
            "unchanged"     => unchanged,
            "hurt"          => hurt,
            "place_changed" => tcs.find { |t| t["name"] == "mutate_location" }&.dig("args", "alteration")
          }.compact, tcs, subsystem: :runner_environment_fragment)
        end

        # A pure-flavor poke that committed nothing stays blank when a sibling
        # runner renders; the null_line covers the solo case (the old "let
        # narration render it" assumed the executed narrator).
        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok,
                    null_line: (tcs.empty? ? "Nothing comes of it — #{action}." : nil))
      end

      private

      # Loot from the environment: a real Item straight into the player's
      # hands — gather-acts are acquisitive, and the narration says "in your
      # grasp", so the row must agree (anchored-here yields read as vanished:
      # run-20260820-115058, three turns lost to a branch "on the ground").
      def spawn_item(resolver, item, action, player, tcs)
        return unless item.is_a?(Hash)
        name = item["name"].to_s.strip
        return if name.empty?
        execute_tool(resolver, "propose_item", {
          "name"         => name,
          "subrole"      => item["subrole"].to_s.strip.presence || "object",
          "connection"   => "yielded by the player's interaction: #{action}",
          "character_id" => player.id,
          "properties"   => item["properties"].is_a?(Hash) ? item["properties"] : {}
        }, into: tcs)
      end

      # Rework an existing REAL item — held by the player or anchored here —
      # into something else via mutate_item: the row persists, changed
      # (sharpen a branch into a stake). Items elsewhere or in someone
      # else's hands are out of reach. Returns {"was","now"} for the
      # fragment, or nil when nothing committed.
      def transform_item(resolver, spec, action, player, context, tcs)
        return nil unless spec.is_a?(Hash)
        item = ::Item.find_by(id: spec["item_id"])
        return nil unless item
        held = item.character_id == player.id
        here = item.location_id && item.location_id == context.player_location&.id
        return nil unless held || here
        was = item.name
        committed = false
        { "name" => spec["name"], "subrole" => spec["subrole"] }.each do |field, value|
          v = value.to_s.strip
          next if v.empty? || v == item.read_attribute(field)
          _res, ok = execute_tool(resolver, "mutate_item", { "item_id" => item.id, "field" => field, "value" => v }, into: tcs)
          committed ||= ok
        end
        return nil unless committed
        consumed = consume_component(resolver, spec["consumes_item_id"], item, action, player, context, tcs)
        { "was" => was, "now" => item.reload.name, "consumed" => consumed }.compact
      end

      # The making can bind in a SECOND real item (rope wrapped onto the
      # club) — used up, so destroyed, but only when the work itself
      # committed. Same reach guard as the item being worked.
      def consume_component(resolver, component_id, worked_item, action, player, context, tcs)
        return nil unless component_id.is_a?(Integer) && component_id != worked_item.id
        comp = ::Item.find_by(id: component_id)
        return nil unless comp
        held = comp.character_id == player.id
        here = comp.location_id && comp.location_id == context.player_location&.id
        return nil unless held || here
        res, ok = execute_tool(resolver, "destroy_item", {
          "item_id" => comp.id,
          "reason"  => "used up in: #{action}"
        }, into: tcs)
        ok ? res["item_name"] : nil
      end

      # The botch with teeth: a CRITICAL failure while reworking an item
      # destroys the item being worked ("falls apart into scrap" narration
      # had no state behind it — run-20260821-130253). Same reach guard as
      # the transform; plain failures leave the item untouched. Returns the
      # destroyed item's name for the fragment, or nil.
      def ruin_item(resolver, spec, action, player, context, tcs)
        return nil unless spec.is_a?(Hash)
        item = ::Item.find_by(id: spec["item_id"])
        return nil unless item
        held = item.character_id == player.id
        here = item.location_id && item.location_id == context.player_location&.id
        return nil unless held || here
        res, ok = execute_tool(resolver, "destroy_item", {
          "item_id" => item.id,
          "reason"  => "ruined in a badly botched attempt: #{action}"
        }, into: tcs)
        ok ? res["item_name"] : nil
      end

      # The third payer on a botch, beside the place and the thing: the body.
      # The emit names only WHAT hurts; the engine owns how much — a slight
      # 1d3 from the turn's dice stream (replay-stable), never below 1 HP
      # (a botched carving cannot kill). Recorded like the fragment, as the
      # runner's own committed change, so Parts renders the number and the
      # fragment dresses a written fact instead of inventing a cut.
      HARM_DIE = 3
      def harm_player(what, player, tcs)
        what = what.to_s.strip
        return nil if what.empty?
        damage = [ ::Harness::RNG.current.rand(1..HARM_DIE), player.current_hp.to_i - 1 ].min
        return nil if damage <= 0
        player.update!(current_hp: player.current_hp - damage)
        tcs << { "name" => "harm", "args" => { "what" => what },
                 "result" => { "damage" => damage, "current_hp" => player.current_hp, "max_hp" => player.max_hp } }
        { "what" => what, "damage" => damage }
      end

      def alter_location(resolver, change, context, tcs)
        note = change.to_s.strip
        return if note.empty?
        execute_tool(resolver, "mutate_location", {
          "location_id" => context.player_location.id,
          "alteration"  => note
        }, into: tcs)
      end

      def decide(context, input, step, player, scene)
        loc = context.player_location
        user = JSON.pretty_generate(
          "player_input" => input,
          "intent"       => step&.intent,
          "player"       => {
            "id"        => player.id,
            "name"      => player.name,
            "abilities" => Array(player.abilities).map { |a| a.is_a?(Hash) ? a["name"] : a }
          },
          "location" => {
            "name"        => loc&.name,
            "description" => loc&.description,
            # Persistent player-made changes (a barred door, a breached wall),
            # so the runner honors them instead of acting on a pristine place.
            "alterations" => (loc&.properties.is_a?(Hash) ? loc.properties["alterations"] : nil)
          }.compact,
          # The concrete objects actually anchored here — so the act grounds in
          # a real thing (search THIS crate) instead of one the model invents.
          # Ids ride along so transforms_item can reference the row; free-text
          # features still have no id and can never transform.
          "present_objects" => Array(scene && scene["present_items"]).map { |i| { "id" => i["id"], "name" => i["name"] } },
          "held_items"      => ::Item.where(character_id: player.id).order(:id).map { |i| { "id" => i.id, "name" => i.name } }
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_environment) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        parse_emit(raw)
      rescue StandardError => e
        @logger.warn { "[Runner environment] decide failed: #{e.class}: #{e.message}" }
        nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
