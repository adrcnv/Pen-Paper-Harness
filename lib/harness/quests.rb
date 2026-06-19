module Harness
  # Top-level Quests module + feature gate.
  #
  # The quest system (Generator at scene entry, FulfillmentCheck at end of
  # turn, AcceptQuest in the tool registry) is OFF by default while the
  # local-Qwen hydrator-rejection rate is too high to be playable. Set
  # HARNESS_QUESTS=on (or 1/true/yes) to re-enable.
  #
  # The submodule classes (Generator, FulfillmentCheck, AcceptQuest, ...)
  # are untouched — they still work when called directly (tests, future
  # re-enablement). The gate lives at the CALLERS:
  #   - Scene::Manager#maybe_run_quest_generation
  #   - Turn::Loop end-of-turn FulfillmentCheck invocation
  #   - Resolver.tools_for (drops AcceptQuest from the LLM-visible registry)
  module Quests
    TRUTHY = %w[1 on true yes y].freeze

    def self.enabled?
      TRUTHY.include?(ENV["HARNESS_QUESTS"].to_s.strip.downcase)
    end
  end
end
