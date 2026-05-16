module Harness
  module Tools
    class MutateFaction < Base
      COLUMN_FIELDS   = %w[name subrole is_kingdom].freeze
      RESERVED_FIELDS = %w[id created_at updated_at properties].freeze

      def self.tool_name
        "mutate_faction"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Change one attribute of a faction. `field` is either a column (name, subrole, is_kingdom) or a free-form property key (disposition, reach, notable_members, ...). Columns are type-checked — is_kingdom is boolean, name/subrole are strings. Property values are stored verbatim on the faction's properties JSON; passing null for a property field deletes the key. Use this to flip a trading company to a kingdom (is_kingdom → true + subrole → 'kingdom' in two calls), rename, or adjust standing.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "faction_id" => { "type" => "integer" },
              "field"      => { "type" => "string" },
              "value"      => { "description" => "new value; null deletes a property key" }
            },
            "required" => [ "faction_id", "field" ]
          }
        }
      end

      def call(args, context)
        id    = args["faction_id"]
        field = args["field"]
        value = args["value"]

        return { "error" => "faction_id required" } if id.nil?
        return { "error" => "field must be a non-empty string" } unless field.is_a?(String) && !field.strip.empty?
        return { "error" => "#{field} is a reserved field and cannot be mutated" } if RESERVED_FIELDS.include?(field)

        f = ::Faction.find_by(id: id)
        return { "error" => "no faction with id=#{id}" } unless f

        result = if COLUMN_FIELDS.include?(field)
          update_column(f, field, value)
        else
          merge_property(f, field, value)
        end

        return result if result["error"]

        log_event(f, field, result["old_value"], result["new_value"], context)
        result.merge("id" => f.id, "field" => field)
      end

      private

      def update_column(f, field, value)
        case field
        when "name"
          return { "error" => "name must be a non-empty string" } unless value.is_a?(String) && !value.strip.empty?
          apply(f, field, value)
        when "subrole"
          return { "error" => "subrole must be a string" } unless value.is_a?(String)
          apply(f, field, value)
        when "is_kingdom"
          return { "error" => "is_kingdom must be boolean" } unless [ true, false ].include?(value)
          apply(f, field, value)
        end
      end

      def apply(f, field, value)
        old = f.read_attribute(field)
        f.update!(field => value)
        { "old_value" => old, "new_value" => value }
      end

      def merge_property(f, field, value)
        props = (f.properties || {}).dup
        old   = props[field]
        if value.nil?
          props.delete(field)
        else
          props[field] = value
        end
        f.update!(properties: props)
        { "old_value" => old, "new_value" => value }
      end

      def log_event(f, field, old, new_val, context)
        # Factions don't have a location; events about them are placeless.
        # Participants stays empty — this is a meta-state event, not a person's
        # action. The faction name is captured in details prose for queryability.
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  nil,
          details: {
            "mutation" => {
              "target_type" => "faction",
              "target_id"   => f.id,
              "target_name" => f.name,
              "field"       => field,
              "old_value"   => old,
              "new_value"   => new_val
            }
          },
          participants: []
        )
      end
    end
  end
end
