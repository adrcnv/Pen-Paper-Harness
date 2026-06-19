module Harness
  # Shadow-mode planner harness. A diagnostic that runs a PLANNER LLM call
  # alongside the live agentic reasoning loop WITHOUT executing anything.
  #
  # Purpose (see state_machine_design.md "shadow-mode planner"): before
  # committing to the dispatcher/runner rewrite, gather planner behavior on
  # REAL inputs at zero risk to the playthrough.
  #
  # The locally-relevant question (single GPU-resident model, tok/s-bound):
  #   Does a constrained planner decompose real inputs into sane, bounded
  #   plans — or does it balloon / go silent the way the agentic loop does?
  #   The local win from the rewrite is killing the 20-call runaways and the
  #   silent turns (predictable, bounded per-turn cost with ONE model) — NOT
  #   swapping in a smaller model. Local play is always single-model.
  #
  # The two-tier capability below (planning with grunt AND nuance, diffing
  # their plans) is DORMANT INFRA for a future hosted/multi-tenant backend
  # where cost optimization across model tiers matters. It is NOT a local
  # knob: the GPU can't hold two models, and a GPU big enough to hold two has
  # no tok/s reason to bother. Don't design local experiments around it.
  #
  # The planner executes NO tools and mutates NO state. It only emits a plan
  # which we log next to what the agentic loop actually did, for offline
  # comparison. Everything here is failure-isolated: any error logs a warning
  # and the live turn proceeds untouched.
  #
  # OFF by default. Set HARNESS_SHADOW_PLANNER=on (or 1/true/yes) to enable.
  module Shadow
    TRUTHY = %w[1 on true yes y].freeze

    def self.enabled?
      TRUTHY.include?(ENV["HARNESS_SHADOW_PLANNER"].to_s.strip.downcase)
    end
  end
end
