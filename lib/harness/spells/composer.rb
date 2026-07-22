module Harness
  module Spells
    # The reasoning half of composed magic — a genesis-shaped call that turns
    # a spell's PROSE into a mechanical atom block. Two binding modes, split
    # by what the composer is allowed to see (stage-2 ruling):
    #
    #   cached (default `compose:` class) — target-agnostic. Sees the spell
    #   text and the caster's outline only; the block it emits is the spell's
    #   fixed identity, cached onto the ability at first successful cast and
    #   replayed mechanically forever after.
    #
    #   volatile (per-cast, wish-class) — sees the player's actual worded
    #   intent, the bound target's full sheet, and the location, and reasons
    #   the whole cascade fresh every cast ("beautify THIS fisherman =
    #   charisma up + THIS weathered description rewritten"). Never cached.
    #
    # Output is validated against the closed Atoms vocabulary with a repair
    # retry; total failure returns nil and the cast stays prose-only.
    class Composer
      PROMPT_PATH = ::Rails.root.join("lib/harness/prompts/spell_composer.txt")
      MAX_RETRIES = 2

      def initialize(llm:, logger: ::Rails.logger)
        @llm    = llm
        @logger = logger
      end

      # Returns { "atoms" => [...], "narrative" => "..." } or nil.
      # Passing `target:`/`location:`/`intent:` switches to volatile context.
      def compose(spell:, caster:, target: nil, location: nil, intent: nil)
        return nil unless @llm
        payload = {
          "spell"  => { "name" => spell["name"], "description" => spell["description"],
                        "kind" => spell["effect_kind"], "tags" => spell["tags"] }.compact,
          "caster" => { "name" => caster.name, "class" => caster.character_class, "level" => caster.level }
        }
        payload["cast"]     = intent if intent.present?
        payload["target"]   = target_sheet(target) if target
        payload["location"] = { "name" => location.name, "description" => location.description }.compact if location

        user = "INPUT:\n#{::JSON.pretty_generate(payload)}"
        attempts = 0
        loop do
          attempts += 1
          raw = ::Harness::CostTracker.in_subsystem(:spell_composer) do
            @llm.complete(system: preamble, user: user)
          end
          parsed = ::Harness::LLM::JsonResponse.parse(raw)
          errors = validate(parsed)
          if errors.empty?
            @logger.info { "[Spells::Composer] #{spell['id']}: #{parsed['atoms'].map { |a| a['kind'] }.join(',')} (attempt #{attempts})" }
            return parsed.slice("atoms", "narrative")
          end
          @logger.warn { "[Spells::Composer] rejected (attempt #{attempts}/#{MAX_RETRIES + 1}): #{errors.join('; ')}" }
          return nil if attempts > MAX_RETRIES
          user = repair_user(user, raw, errors)
        end
      rescue ::StandardError => e
        @logger.warn { "[Spells::Composer] failed: #{e.class}: #{e.message}" }
        nil
      end

      private

      def validate(parsed)
        return [ "output must be a JSON object" ] unless parsed.is_a?(::Hash)
        errors = Atoms.validate(parsed["atoms"])
        errors << "narrative must be a non-empty string" unless parsed["narrative"].is_a?(::String) && !parsed["narrative"].strip.empty?
        errors
      end

      # The volatile mode's whole point: the composer reasons about THIS
      # target, so it gets the real sheet — stats, purse, prose, holdings.
      def target_sheet(char)
        props = char.properties || {}
        {
          "name"    => char.name,
          "subrole" => char.subrole,
          "class"   => char.character_class,
          "level"   => char.level,
          "stats"   => ::Character::STATS.index_with { |s| char.stat(s) },
          "hp"      => "#{char.current_hp}/#{char.max_hp}",
          "coins"   => char.coins.to_i,
          "gender"      => props["gender"],
          "personality" => props["personality"],
          "appearance"  => props["appearance"] || props["physical"],
          "items"       => char.items.map(&:name)
        }.compact
      end

      def repair_user(original, bad, errors)
        <<~REPAIR
          #{original}

          YOUR PREVIOUS OUTPUT WAS REJECTED. Here is what you produced:
          #{bad}

          ERRORS:
          #{errors.map { |e| "- #{e}" }.join("\n")}

          Fix ALL errors and output the corrected JSON. No prose around the object.
        REPAIR
      end

      def preamble
        @preamble ||= ::File.read(PROMPT_PATH)
      end
    end
  end
end
