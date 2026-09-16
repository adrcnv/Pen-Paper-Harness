module Harness
  module LLM
    # Abstract adapter. Two shapes:
    #   tool loop  — start_turn yields tool calls; caller feeds results back
    #                until the model stops calling tools (combat slots).
    #   completion — plain prompt → string.
    # Real HTTP adapters (Anthropic, OpenAI, Ollama) implement this.
    class Adapter
      def start_turn(system:, user:, tools:)
        raise NotImplementedError
      end

      # temperature / thinking: per-call sampling. Judges that answer in ids
      # and enums run at zero temperature; prose into a buffer (a voice
      # line, the eyes) runs at the server default. Thinking mode is off
      # everywhere (ruled 2026-09-16 — a judge that needs to reflect writes
      # a directed field first). nil = the adapter's configured default.
      def complete(system:, user:, schema: nil, max_tokens: nil, temperature: nil, thinking: nil)
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
