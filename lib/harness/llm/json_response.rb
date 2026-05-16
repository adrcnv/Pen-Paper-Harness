require "json"

module Harness
  module LLM
    # Models love wrapping JSON output in markdown code fences (```json ... ```)
    # even when the prompt says not to. Haiku is especially fond of it. Strip
    # the fence if present, then parse — prompt instructions alone are not
    # reliable across model tiers.
    module JsonResponse
      # Matches a code fence with optional language tag, capturing inner body.
      # Tolerant of leading/trailing whitespace.
      FENCE_RE = /\A\s*```[a-zA-Z]*\s*\n?(.*?)\n?\s*```\s*\z/m

      def self.parse(text)
        body = text
        if (m = body.match(FENCE_RE))
          body = m[1]
        end
        JSON.parse(body)
      end
    end
  end
end
