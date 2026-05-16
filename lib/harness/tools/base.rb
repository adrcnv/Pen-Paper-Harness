module Harness
  module Tools
    # Tool = schema + call. Schemas are in Anthropic-native tool-use format
    # so a real adapter can forward them straight to the API. Call receives
    # parsed args (hash) and the per-turn context (TurnContext), returns a
    # hash. Any raise is caught by the Resolver and rewritten as {error: ...}
    # so the reasoning loop can recover instead of hard-crashing the turn.
    class Base
      def self.tool_name
        raise NotImplementedError
      end

      def self.schema
        raise NotImplementedError
      end

      def call(args, context)
        raise NotImplementedError
      end
    end
  end
end
