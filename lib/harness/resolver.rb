module Harness
  # Dispatches reasoning-loop tool calls to their Tool classes and guarantees
  # the loop never sees a raised exception. Every error comes back as
  # {"error" => "..."} so the LLM can try a different tool or recover.
  #
  # Held registry is the set of tools the reasoning loop is allowed to call this turn.
  # Narrower registries are fine (e.g. a "talk-only" scene that omits
  # transition). The default registry is the full set.
  class Resolver
    DEFAULT_TOOLS = [
      Tools::QueryScene,
      Tools::QueryCharacter,
      Tools::QueryEvents,
      Tools::QueryFaction,
      Tools::QueryItem,
      Tools::QueryInventory,
      Tools::QueryLocationByName,
      Tools::QueryJourney,
      Tools::MutateCharacter,
      Tools::MutateFaction,
      Tools::MutateItem,
      Tools::TransferCoins,
      Tools::Pickup,
      Tools::Drop,
      Tools::GiveItem,
      Tools::Resolve,
      Tools::AwardXP,
      Tools::Transition,
      Tools::Travel,
      Tools::PassTime,
      Tools::ProposeEvent,
      Tools::ProposeCharacter,
      Tools::ProposeFaction,
      Tools::ProposeItem,
      Tools::ProposeLocation,
      Tools::AcceptQuest,
      ::Harness::Combat::Tools::StartCombat
    ].freeze

    # Combat-mode registry. While scene.in_combat? is true, the reasoning
    # loop sees this narrowed surface only — no transitions, no proposals
    # for new entities, no general queries. The round driver (Combat::Loop)
    # picks this set when invoking the reasoning loop on the player's slot.
    # See COMBAT_DESIGN.md "Combat-mode tool surface (narrow)" for the rule.
    COMBAT_TOOLS = [
      Tools::QueryScene,
      Tools::Resolve,
      Tools::MutateCharacter,
      Tools::ProposeEvent,
      ::Harness::Combat::Tools::MoveTo,
      ::Harness::Combat::Tools::EndTurn,
      ::Harness::Combat::Tools::Escape
    ].freeze

    # NPC-slot registry — strictly the action tools an NPC needs to decide
    # their slot. No QueryScene (their payload already has every id, hp,
    # position, ability, and engagement — querying just wastes the slot on
    # a lookup). No MutateCharacter (HP/state changes flow through resolve).
    # No ProposeEvent (NPCs don't author world events from their slot).
    NPC_TURN_TOOLS = [
      Tools::Resolve,
      ::Harness::Combat::Tools::MoveTo,
      ::Harness::Combat::Tools::EndTurn,
      ::Harness::Combat::Tools::Escape
    ].freeze

    def self.default_schemas
      DEFAULT_TOOLS.map(&:schema)
    end

    # Returns the right tool registry for this turn's mode. Caller passes the
    # turn context; reads context.active_scene&.in_combat?. In combat,
    # COMBAT_TOOLS; otherwise the supplied normal-mode registry (defaults to
    # DEFAULT_TOOLS).
    def self.tools_for(context, normal_tools: DEFAULT_TOOLS)
      return COMBAT_TOOLS if context&.active_scene&.in_combat?
      return normal_tools if ::Harness::Quests.enabled?
      normal_tools.reject { |t| t == Tools::AcceptQuest }
    end

    def initialize(context:, tools: DEFAULT_TOOLS, logger: Rails.logger)
      @context = context
      @logger  = logger
      @by_name = tools.each_with_object({}) { |t, h| h[t.tool_name] = t.new }
    end

    def schemas
      @by_name.values.map(&:class).map(&:schema)
    end

    def execute(tool_call)
      tool = @by_name[tool_call.name]
      return { "error" => "unknown tool: #{tool_call.name}" } unless tool

      args = tool_call.args || {}
      if (leak_path = detect_xml_tool_leak(args))
        @logger.warn { "[Resolver] #{tool_call.name} XML tool-call leak in arg '#{leak_path}'" }
        return { "error" => "tool args must be JSON; XML tool-call syntax (e.g. <parameter ...> or antml:parameter) detected in arg '#{leak_path}'. Re-emit this call with all arguments as proper JSON fields." }
      end

      @logger.debug { "[Resolver] -> #{tool_call.name} #{args.inspect}" }
      result = tool.call(args, @context)
      @logger.debug { "[Resolver] <- #{tool_call.name} #{result.inspect.slice(0, 300)}" }
      result
    rescue StandardError => e
      @logger.warn { "[Resolver] #{tool_call.name} raised: #{e.class}: #{e.message}" }
      { "error" => "#{e.class.name}: #{e.message}" }
    end

    private

    # Models occasionally regress to legacy XML tool-call format mid-call,
    # leaking '<parameter name="x">value</parameter>' or 'antml:parameter'
    # syntax inside string fields when they meant to pass a separate top-level
    # arg. Catches the leak so the agentic loop sees an error and retries
    # cleanly instead of committing the malformed prose to the database.
    # Returns the offending key path on detection, nil otherwise.
    XML_LEAK_PATTERN = /<\s*\/?\s*parameter\b|antml:parameter|<\s*\/?\s*invoke\b/i

    def detect_xml_tool_leak(args, path = "")
      case args
      when String
        args.match?(XML_LEAK_PATTERN) ? (path.empty? ? "(root)" : path) : nil
      when Hash
        args.each do |k, v|
          sub = detect_xml_tool_leak(v, path.empty? ? k.to_s : "#{path}.#{k}")
          return sub if sub
        end
        nil
      when Array
        args.each_with_index do |v, i|
          sub = detect_xml_tool_leak(v, "#{path}[#{i}]")
          return sub if sub
        end
        nil
      end
    end
  end
end
