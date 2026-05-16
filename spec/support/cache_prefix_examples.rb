# Shared example for materializer cache-prefix stability.
#
# Each materializer's prompt is split into {system, user}. Anthropic (and any
# adapter that supports prompt caching) places its cache breakpoint on the
# system portion; the cache only hits if `system` bytes are byte-identical
# across calls within the cache TTL. This example asserts that invariant.
#
# Including specs MUST define:
#   - let(:llm)      — a StubLLM the materializer talks to
#   - let(:exercise) — a callable that runs the materializer multiple times
#                      with materially different inputs (and ideally a retry
#                      path) using `llm`
#
# After exercise, llm.assert_stable_system! verifies the system bytes were
# identical across every recorded .complete call.
#
# Failure surface this catches:
#   - Per-call data accidentally interpolated into Prompt.render's system part
#   - Repair-retry feedback leaking into system instead of user
#   - Materializer code path varying which preamble file it loads
RSpec.shared_examples "stable cache prefix" do
  it "keeps system bytes byte-stable across calls (cache prefix preserved)" do
    exercise.call
    expect(llm.system_calls.size).to be > 1, "exercise must trigger more than one .complete call to be a meaningful cache regression test"
    llm.assert_stable_system!
  end
end
