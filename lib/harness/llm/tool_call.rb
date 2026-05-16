module Harness
  module LLM
    ToolCall = Struct.new(:name, :args, keyword_init: true)
  end
end
