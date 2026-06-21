module Harness
  module Settlement
    # Resolve a location's settlement identity by walking up to the enclosing
    # top-level city and reading its denormalized profile. A sublocation
    # inherits its town's terrain + economic basis/size/wealth. Single source
    # for query_scene's `setting` block and the economy's pricing context.
    module Facts
      KEYS = %w[terrain coastal riverside economic_basis size wealth].freeze

      module_function

      # Full hash (values may be nil for placeless / pre-geography locations).
      def for(location)
        owner = location
        owner = owner.parent while owner&.parent_id
        props = owner&.properties
        return {} unless props.is_a?(Hash)
        KEYS.each_with_object({}) { |k, h| h[k] = props[k] unless props[k].nil? }
      end

      # Compact hash or nil — for surfacing where "no setting" should be omitted.
      def presentable(location)
        f = self.for(location)
        f.empty? ? nil : f
      end
    end
  end
end
