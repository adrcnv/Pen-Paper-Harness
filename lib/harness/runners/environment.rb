module Harness
  module Runners
    # The player physically acts on a scene OBJECT or feature that is NOT a
    # character — smash, burn, blast, search, pry, dig, cut, barricade. One
    # structured call classifies the act; Ruby orchestrates the real tools:
    #   - resolve         when the attempt is uncertain (a roll)
    #   - propose_item    when it yields something collectible (anchored here)
    #   - mutate_location when it persistently alters the place
    # A pure-flavor poke (kick a wall, rattle a stuck gate) emits nothing and
    # lets narration render it. This is the runner the "blast the tree, collect
    # the wood" input had no home for — it used to flail dice → inventory →
    # combat → unresolved.
    #
    # Consequences (item / alteration) are gated on the roll NOT failing, so a
    # botched blast yields no firewood and no lasting damage.
    class Environment < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/environment.txt")

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
          roll_ok = !(res.is_a?(Hash) && res["outcome"].to_s.downcase.include?("fail"))
        end

        if roll_ok
          spawn_item(resolver, spec["yields_item"], action, context, tcs)
          alter_location(resolver, spec["location_change"], context, tcs)
        end

        Outcome.new(tool_calls: tcs, scene_dirty: false, status: :ok)
      end

      private

      # Loot from the environment: a real Item anchored to the current location
      # so a follow-up pickup finds something. The engine rolls the item's real
      # properties; the emit only names what kind of thing it is.
      def spawn_item(resolver, item, action, context, tcs)
        return unless item.is_a?(Hash)
        name = item["name"].to_s.strip
        return if name.empty?
        execute_tool(resolver, "propose_item", {
          "name"        => name,
          "subrole"     => item["subrole"].to_s.strip.presence || "object",
          "connection"  => "yielded by the player's interaction: #{action}",
          "location_id" => context.player_location.id,
          "properties"  => item["properties"].is_a?(Hash) ? item["properties"] : {}
        }, into: tcs)
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
          # Names only; environment acts on free-text features, not by id.
          "present_objects" => Array(scene && scene["present_items"]).map { |i| i["name"] }.compact
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
