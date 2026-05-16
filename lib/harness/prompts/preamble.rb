module Harness
  module Prompts
    # Loads a preamble .txt file and substitutes vocabulary placeholders.
    #
    # Placeholders use {{UPPER_SNAKE}} markers in the .txt files. The values
    # come from model/config constants, so adding a new scope/subrole/terrain
    # propagates to every prompt automatically.
    #
    # Placeholders not in `vocabulary` are left unchanged (no-op replace).
    module Preamble
      def self.load(path)
        render(File.read(path))
      end

      def self.render(text)
        vocabulary.each { |placeholder, value| text = text.gsub(placeholder, value) }
        text
      end

      def self.vocabulary
        {
          "{{SCOPES}}"                     => ::Event::ALLOWED_SCOPES.join(", "),
          "{{KINGDOM_SUBROLES}}"           => ::Faction::KINGDOM_SUBROLES.join(" | "),
          "{{KINGDOM_SUBROLES_HUMAN}}"     => humanize_list(::Faction::KINGDOM_SUBROLES),
          "{{NON_KINGDOM_SUBROLES}}"       => ::Faction::NON_KINGDOM_SUBROLES.join(", "),
          "{{NON_KINGDOM_SUBROLES_HUMAN}}" => humanize_list(::Faction::NON_KINGDOM_SUBROLES),
          "{{TERRAINS}}"                   => ::Location::ALLOWED_TERRAINS.join(" | "),
          "{{KINGDOM_ONLY_KINDS}}"         => ::Location::KINGDOM_ONLY_KINDS.join(", ")
        }
      end

      # snake_case -> "snake case", joined with commas, for embedding in prose.
      def self.humanize_list(values)
        values.map { |v| v.to_s.tr("_", " ") }.join(", ")
      end
    end
  end
end
