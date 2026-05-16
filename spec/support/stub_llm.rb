# Test double for materializer LLM clients.
#
# Materializers call `llm.complete(system:, user:)` — provider-neutral; matches
# the shape every adapter (Anthropic, OpenAI-compat, local) accepts. StubLLM
# records the system + user separately so cache-prefix regression specs can
# assert "system bytes stay byte-identical across calls."
#
# The block receives the combined "system\nuser" string so existing specs that
# route by inspecting prompt keywords keep working. Specs that only need the
# user portion can read llm.user_calls.last.
#
# Strict mode (`StubLLM.new(strict: true) { ... }`) raises immediately when a
# subsequent .complete call sees a different system than the previous one.
# Useful for materializer specs that want loud failure at write time. NOT
# default — some specs share a single StubLLM across multiple materializers
# (e.g., scene/manager_spec.rb routes genesis/internal-state/catch-up through
# one client) and those legitimately see different system messages.
class StubLLM
  class CacheDriftError < StandardError; end

  attr_reader :system_calls, :user_calls

  def initialize(strict: false, &block)
    @block        = block
    @strict       = strict
    @system_calls = []
    @user_calls   = []
  end

  def complete(system:, user:)
    if @strict && @system_calls.any? && @system_calls.last != system
      raise CacheDriftError, drift_message(@system_calls.last, system)
    end
    @system_calls << system
    @user_calls   << user
    @block.call("#{system}\n#{user}")
  end

  # Back-compat for materializers that haven't moved to .complete yet.
  def call(prompt)
    @user_calls << prompt
    @block.call(prompt)
  end

  # Assert all recorded .complete calls used byte-identical system. The cache
  # prefix invariant: if this fails, any prompt-cache the adapter sets up will
  # miss on every call. Use in regression specs after exercising the
  # materializer with multiple inputs (and ideally a retry path).
  def assert_stable_system!
    return if @system_calls.empty?
    unique = @system_calls.uniq
    return if unique.size == 1
    raise CacheDriftError, drift_summary(unique)
  end

  def stable_system?
    @system_calls.empty? || @system_calls.uniq.size == 1
  end

  private

  def drift_message(prev, current)
    "system bytes drifted between calls (cache prefix would miss).\n" \
    "Previous (#{prev.bytesize} bytes): #{prev.slice(0, 200).inspect}...\n" \
    "Current  (#{current.bytesize} bytes): #{current.slice(0, 200).inspect}..."
  end

  def drift_summary(variants)
    "system bytes drifted across #{@system_calls.size} calls — #{variants.size} variants seen.\n" +
      variants.each_with_index.map { |s, i| "  [#{i}] #{s.bytesize} bytes, head: #{s.slice(0, 160).inspect}" }.join("\n")
  end
end
