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

      def redispatch(note, tool_calls = [])
        Outcome.new(tool_calls: tool_calls, scene_dirty: false, status: :redispatch, note: note)
      end

      # Promote an ambient `extra` (a `present_extras` description string) into a
      # real Npc so a runner can target it. The weak model cannot act on a
      # nameless figure — `present_characters` is the only thing the conversation
      # and dice runners can address — so when the player interacts with an
      # extra consequentially (heals it, hits it, speaks to it), the runner
      # names the extra by its INDEX and we materialize it here: mechanical
      # name, runner-supplied subrole, the original description carried as
      # `physical`. propose_character's `from_extra` removes the extra from the
      # scene so it doesn't double-render. We then refresh the scene snapshot
      # (pure SQL) so the new NPC appears in present_characters for narration
      # THIS turn — otherwise it reads from the assembly-time snapshot and the
      # promoted figure would be invisible again.
      #
      # `cache` memoizes index→id so a figure referenced twice in one turn
      # (healed AND spoken to) promotes exactly once. Returns the new id or nil.
      def promote_extra(resolver, context, scene, index, subrole, into:, cache:)
        return cache[index] if cache.key?(index)
        desc = Array(scene && scene["present_extras"])[index]
        return (cache[index] = nil) unless desc.is_a?(String) && desc.strip != ""

        name = ::Harness::Naming.unique_for(location: context.player_location)
        res, ok = execute_tool(resolver, "propose_character", {
          "name"       => name,
          "subrole"    => subrole.to_s.strip.presence || "commoner",
          "connection" => "materialized from an ambient figure the player engaged directly: #{desc}",
          "properties" => { "physical" => desc },
          "from_extra" => desc
        }, into: into)

        id = (ok && res.is_a?(Hash)) ? (res["character_id"] || res["id"]) : nil
        if id && (active = context.active_scene)
          active.snapshot = ::Harness::Scene::Assembler.for(location: context.player_location)
        end
        cache[index] = id
      end
    end
  end
end
