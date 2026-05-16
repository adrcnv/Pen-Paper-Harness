module Harness
  module LLM
    # Abstract adapter. Two shapes:
    #   reasoning (agentic)   — start_turn yields tool calls; caller feeds
    #                           results back until the model stops calling
    #                           tools.
    #   narration (completion) — plain prompt → string.
    # Real HTTP adapters (Anthropic, OpenAI, Ollama) implement this.
    class Adapter
      def start_turn(system:, user:, tools:)
        raise NotImplementedError
      end

      def complete(system:, user:)
        raise NotImplementedError
      end

      # Human-readable model identity for banners and logs. Subclasses
      # override; default falls back to @model if set, else the class name.
      def display_model
        @model || self.class.name
      end
    end
  end
end
