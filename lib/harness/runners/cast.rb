module Harness
  module Runners
    # Out-of-combat ability casting — the thin door for buffs, heals, and
    # targeted casts ("cast shield up", "bless Maren", "heal myself"). ONE
    # structured emit binds the player's free text to an OWNED ability plus an
    # optional present target — the reasoning surface (typos, paraphrases,
    # "cast charm" all land here; never regex). Everything below the emit is
    # Ruby: Tools::Resolve rolls (or auto-applies willing buff/heal casts) and
    # the ability's authored `effect:` block lands on the recipient. In combat
    # this door doesn't exist — combat slots already cast through resolve.
    # Social-pressure casts mid-conversation stay with the conversation
    # runner's contest binding.
    class Cast < Base
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/runners/cast.txt")

      def run(context:, scene:, input:, step:)
        player = ::Player.first
        return redispatch("no player row") unless player
        abilities = Array(player.abilities)
        return redispatch("player has no abilities to cast") if abilities.empty?

        present = Array(scene["present_characters"])
        user = JSON.pretty_generate(
          "player_input" => input,
          "intent"       => step&.intent,
          "abilities"    => abilities.map { |a|
            { "id" => a["id"], "name" => a["name"], "kind" => a["effect_kind"],
              "uses_remaining" => a["uses_remaining"], "description" => a["description"] }
          },
          "present"      => present.map { |c| { "name" => c["name"] } }
        )
        raw = ::Harness::CostTracker.in_subsystem(:runner_cast) do
          llm(context).complete(system: preamble, user: "INPUT:\n#{user}")
        end
        pick    = ::Harness::LLM::JsonResponse.parse(raw)
        ability = pick.is_a?(::Hash) ? player_ability(player, pick["ability"]) : nil
        return redispatch("no castable ability recognized") unless ability

        target = pick.is_a?(::Hash) ? find_present(present, pick["target"]) : nil
        tcs      = []
        resolver = resolver_for(context)
        args = { "actor_id" => player.id, "ability_name" => ability["name"],
                 "action" => (step&.intent.to_s.strip.empty? ? "casts #{ability['name']}" : step.intent) }
        args["target_id"] = target["id"] if target

        res, ok = execute_tool(resolver, "resolve", args, into: tcs)
        unless ok && res.is_a?(::Hash) && res["outcome"]
          return redispatch("cast failed: #{res.is_a?(::Hash) ? res['error'] : 'unparseable resolve'}", tcs)
        end

        # Stage-2 composed magic: on a successful cast, an ability with an
        # atom block (authored, cached, or composed now) commits it.
        scene_dirty = false
        if %w[success critical_success].include?(res["outcome"])
          block = atoms_block(player, ability, target, input, context)
          if block
            commit = ::Harness::Spells::Commit.run(
              atoms:     block["atoms"],
              narrative: block["narrative"],
              spell:     ability,
              caster:    player,
              target:    (::Character.find_by(id: target["id"]) if target),
              context:   context
            )
            tcs.concat(commit["records"])
            scene_dirty = commit["scene_dirty"]
          end
        end

        @logger.info do
          applied = res["effect_applied"] ? " → #{res['effect_applied']['name']} on #{res['effect_applied']['on']}" : ""
          healed  = res["healed"] ? " healed=#{res['healed']}" : ""
          "[Runner cast] #{ability['id']} target=#{target&.dig('name').inspect} #{res['outcome']}#{applied}#{healed}"
        end
        Outcome.new(tool_calls: tcs, scene_dirty: scene_dirty, status: :ok)
      end

      private

      # Which atom block does this cast commit, if any?
      #   volatile     — re-composed EVERY cast (wish-class): the composer
      #                  sees the player's worded intent + the target's full
      #                  sheet + the location. Never cached.
      #   atoms        — authored in the library or cached by a prior cast;
      #                  replays mechanically, no LLM.
      #   compose      — first successful cast binds the spell's prose to a
      #                  target-agnostic block and caches it on the player's
      #                  ability row; later casts hit the atoms branch.
      # Anything else (stage-1 effect blocks, plain damage) returns nil.
      def atoms_block(player, ability, target, input, context)
        if ability["volatile"]
          bound = target && ::Character.find_by(id: target["id"])
          return ::Harness::Spells::Composer.new(llm: llm(context), logger: @logger).compose(
            spell: ability, caster: player, target: bound,
            location: context.player_location, intent: input
          )
        end
        if ability["atoms"].is_a?(::Array) && ability["atoms"].any?
          return { "atoms" => ability["atoms"], "narrative" => ability["atoms_narrative"] }
        end
        return nil unless ability["compose"]

        composed = ::Harness::Spells::Composer.new(llm: llm(context), logger: @logger)
                                              .compose(spell: ability, caster: player)
        cache_atoms!(player, ability, composed) if composed
        composed
      end

      # First-cast binding: write the composed block back onto the player's
      # own ability row. Reload first — resolve already spent a use on this
      # row and a stale write would resurrect it.
      def cache_atoms!(player, ability, composed)
        abilities = Array(player.reload.abilities).map(&:dup)
        idx = abilities.index { |a| a["id"] == ability["id"] }
        return unless idx
        abilities[idx] = abilities[idx].merge(
          "atoms" => composed["atoms"], "atoms_narrative" => composed["narrative"]
        )
        player.update!(abilities: abilities)
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
