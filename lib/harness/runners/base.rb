module Harness
  module Runners
    # Contract for a runner: given the player input + this step's intent +
    # the LIVE scene, do the narrow work and return an Outcome.
    #
    # Hard rule (locked decision #1): args from the dispatcher are HINTS, not
    # bindings. A runner resolves its own targets from the live scene at
    # execution time — later steps reference state that didn't exist when the
    # plan was made (the NPC the move just materialized). Never trust an id
    # off the plan; re-derive from `scene`.
    class Base
      def initialize(logger: Rails.logger)
        @logger = logger
      end

      # context : Turn::Context (world handle, llm tiers, game_time)
      # scene   : freshly-assembled scene snapshot hash (QueryScene.build shape)
      # input   : the player's raw text this turn
      # step    : Dispatcher::Step (runner label + intent text + arg hints)
      # → Runners::Outcome
      def run(context:, scene:, input:, step:)
        raise NotImplementedError, "#{self.class} must implement #run"
      end

      # Display label for logs.
      def name
        self.class.name.split("::").last.downcase
      end

      private

      # Wrap a result in the tool_call record shape narration expects.
      def tool_call(name, args, result)
        { "name" => name, "args" => args, "result" => result }
      end

      # A resolver over the full tool set. The runner only CALLS the subset it
      # needs — the narrowness is in the runner's code + prompt, not the tool
      # registry. (In structured-emit runners the LLM sees no tools at all.)
      # What the engine has already done this turn, as the receipts shown to
      # the player: earlier steps' tool calls on the transcript plus this
      # runner's own so far. Judges read it so a thing already handed over,
      # bought or paid for is history to them, not a fresh act.
      RECEIPT_CALLS = %w[pickup drop give_item trade_items transfer_coins buy_item sell_item offer_item destroy_item
                         wager_void wager_stake haggled npc_leave resolve contest_standing contest_chance].freeze
      def receipts_this_turn(context, tcs)
        calls = Array(context.turn_transcript&.tool_calls) + Array(tcs)
        calls.filter_map do |tc|
          next unless RECEIPT_CALLS.include?(tc["name"])
          ::Harness::Turn::Parts.render_call(tc, context, nil)&.dig(:text).presence
        end
      end

      # What the engine did, refused and answered this turn, for a judge
      # reading from a CHARACTER's seat: the receipts as the player saw them
      # (they name both parties), a refusal of the player's hands as a
      # third-person fact (the player's own line — "you keep your coin" —
      # read from the smith's seat as the smith keeping it, deeds-3 t5), a
      # barred door's reason, the asks route's own line, and the other
      # runners' null lines as before.
      def engine_this_turn(context, tcs)
        calls = Array(context.turn_transcript&.tool_calls) + Array(tcs)
        receipts_this_turn(context, tcs) +
          calls.filter_map { |tc|
            case tc["name"]
            when "hands_refused"    then tc.dig("result", "fact").presence
            when "transition"       then ::Harness::Turn::Parts.render_call(tc, context, nil)&.dig(:text) if tc.dig("result", "refused") == "closed"
            when "resolve_location" then tc.dig("result", "line").presence
            end
          } +
          Array(context.turn_transcript&.null_lines)
      end

      def resolver_for(context)
        ::Harness::Resolver.new(context: context, tools: ::Harness::Resolver::DEFAULT_TOOLS, logger: @logger)
      end

      # Execute a tool, append the {name,args,result} record to `into`, and
      # return [result, ok?]. ok? is false when the tool returned an error.
      def execute_tool(resolver, name, args, into:)
        call   = ::Harness::LLM::ToolCall.new(name: name, args: args.compact)
        result = resolver.execute(call)
        into << tool_call(name, args.compact, result)
        ok = !(result.is_a?(Hash) && result.key?("error"))
        @logger.debug { "[Runner #{self.name}] #{name} -> #{ok ? 'ok' : "ERR #{result['error']}"}" }
        [ result, ok ]
      end

      # The session model for this runner's structured-emit call. Single model
      # locally; llm_nuance is the reasoning tier, grunt the fallback.
      def llm(context)
        context.llm_nuance || context.llm_grunt
      end

      # Per-runner display fragment (the delta-prose island): the organ that
      # committed a change renders its OWN delta as a few short sentences and
      # ships it through the tool-call stream as a display record — Parts
      # renders {name: "display_fragment"} as a :fragment part in causal
      # order, and /debug shows exactly what was rendered. Failure-isolated:
      # a flaked call adds nothing and the mechanical parts carry the turn.
      FRAGMENT_MAX_TOKENS = 160
      # SANITY CEILING on every judge answer (ids, enums, ten words of
      # reasoning): the largest honest answer in run 6 was 145 tokens. Under
      # a grammar, a stray quote inside the reasoning string leaves whitespace
      # as the only legal token, and the answer runs to the adapter's 8192
      # (the struck judge, run 6 t18: two answers of 8192 blanks, ~100 s).
      # A capped runaway is a three-second miss instead.
      JUDGE_MAX_TOKENS = 384

      # How each of these characters looks, by id — the appearance the
      # materializer wrote.
      def looks_for(ids)
        ::Npc.where(id: ids).index_by(&:id).transform_values do |n|
          pr = n.properties
          pr.is_a?(::Hash) ? (pr["physical"].presence || pr["appearance"].presence) : nil
        end
      end
      # A retry echoes the rejected answer back once; a runaway must not ride
      # along whole (the same t18: 8k blanks re-sent, and the retry ran again).
      RETRY_ECHO_MAX = 600
      def echo_for_retry(raw)
        s = raw.to_s
        s.length > RETRY_ECHO_MAX ? "#{s[0, RETRY_ECHO_MAX]}\n… [#{s.length - RETRY_ECHO_MAX} more characters cut]" : s
      end

      def emit_fragment(context, prompt_path, payload, tcs, subsystem:)
        text = ::Harness::CostTracker.in_subsystem(subsystem) do
          llm(context).complete(
            system:     File.read(prompt_path),
            user:       "INPUT:\n#{JSON.pretty_generate(payload)}",
            max_tokens: FRAGMENT_MAX_TOKENS
          ).to_s.strip
        end
        return if text.empty?
        tcs << { "name" => "display_fragment", "args" => { "text" => text }, "result" => { "rendered" => true } }
      rescue StandardError => e
        @logger.warn { "[Runner #{name}] fragment failed (#{e.class}: #{e.message}) — mechanical parts carry the turn" }
      end

      # Tolerant JSON parse for structured-emit output (fences, stray prose).
      # Returns a Hash, or nil on total failure.
      def parse_emit(raw)
        ::Harness::LLM::JsonResponse.parse(raw).then { |o| o.is_a?(Hash) ? o : nil }
      rescue StandardError
        text = raw.to_s
        s = text.index("{"); e = text.rindex("}")
        return nil unless s && e && e > s
        begin
          JSON.parse(text[s..e])
        rescue StandardError
          nil
        end
      end

      def redispatch(note, tool_calls = [], null_line: nil)
        Outcome.new(tool_calls: tool_calls, scene_dirty: false, status: :redispatch, note: note, null_line: null_line)
      end

      # Deterministic dead end (the referent doesn't exist) — the executor
      # stalls this step and continues the chain instead of re-planning.
      def skip(note, tool_calls = [], null_line: nil)
        Outcome.new(tool_calls: tool_calls, scene_dirty: false, status: :skipped, note: note, null_line: null_line)
      end

      # Present-roster lookup, first-token tolerant ("Dobrila" matches
      # "Dobrila Drozdov"). Shared by the contest binding (conversation) and
      # the cast runner.
      def find_present(present, name)
        n = name.to_s.strip.downcase
        return nil if n.empty?
        Array(present).find do |c|
          cn = c["name"].to_s.strip.downcase
          cn == n || cn.split(/\s+/).first == n || cn.split(/\s+/).first == n.split(/\s+/).first
        end
      end

      # Bind a model-emitted ability reference to one the player actually owns
      # (id or name, space/underscore-insensitive). Unowned/absent → nil.
      def player_ability(player, ref)
        r = ref.to_s.strip.downcase.tr(" ", "_")
        return nil if r.empty?
        Array(player.abilities).find do |a|
          a["id"].to_s.downcase == r || a["name"].to_s.strip.downcase.tr(" ", "_") == r
        end
      end

    end
  end
end
