module Harness
  module Tools
    class MutateCharacter < Base
      COLUMN_FIELDS   = %w[name subrole location_id strength dexterity constitution intelligence wisdom charisma].freeze
      STAT_FIELDS     = ::Character::STATS
      STAT_RANGE      = (1..30).freeze
      RESERVED_FIELDS = %w[id type created_at updated_at properties].freeze

      def self.tool_name
        "mutate_character"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Change one attribute of a character. `field` names either a column (name, subrole, location_id, or a stat: strength/dexterity/constitution/intelligence/wisdom/charisma) or a free-form property key (hp, stance, mood, ...). Column values are type-checked and stats are clamped to [1,30]. Property values are stored verbatim on the character's properties JSON; passing null for a property field deletes the key. Each successful mutation logs a personal-scope event with the character as subject.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "character_id" => { "type" => "integer" },
              "field"        => { "type" => "string", "description" => "column name or free-form property key" },
              "value"        => { "description" => "new value; type depends on field; null deletes a property key" }
            },
            "required" => [ "character_id", "field" ]
          }
        }
      end

      def call(args, context)
        id    = args["character_id"]
        field = args["field"]
        value = args["value"]

        return { "error" => "character_id required" } if id.nil?
        return { "error" => "field must be a non-empty string" } unless field.is_a?(String) && !field.strip.empty?
        return { "error" => "#{field} is a reserved field and cannot be mutated" } if RESERVED_FIELDS.include?(field)

        char = ::Character.find_by(id: id)
        return { "error" => "no character with id=#{id}" } unless char

        result = if COLUMN_FIELDS.include?(field)
          update_column(char, field, value)
        else
          merge_property(char, field, value)
        end

        return result if result["error"]

        log_event(char, field, result["old_value"], result["new_value"], context)
        result.merge("id" => char.id, "field" => field)
      end

      private

      def update_column(char, field, value)
        case field
        when "name"
          return { "error" => "name must be a non-empty string" } unless value.is_a?(String) && !value.strip.empty?
          apply(char, field, value)
        when "subrole"
          return { "error" => "subrole must be a string" } unless value.is_a?(String)
          apply(char, field, value)
        when "location_id"
          return apply(char, field, nil) if value.nil?
          return { "error" => "location_id must be integer or null" } unless value.is_a?(Integer)
          return { "error" => "no location with id=#{value}" } unless ::Location.exists?(id: value)
          apply(char, field, value)
        when *STAT_FIELDS
          return { "error" => "#{field} must be an integer" } unless value.is_a?(Integer)
          clamped = value.clamp(STAT_RANGE.min, STAT_RANGE.max)
          out = apply(char, field, clamped)
          out["clamped"] = true if clamped != value
          out
        end
      end

      def apply(char, field, value)
        old = char.read_attribute(field)
        char.update!(field => value)
        { "old_value" => old, "new_value" => value }
      end

      def merge_property(char, field, value)
        props = (char.properties || {}).dup
        old   = props[field]
        if value.nil?
          props.delete(field)
        else
          props[field] = value
        end
        char.update!(properties: props)
        { "old_value" => old, "new_value" => value }
      end

      def log_event(char, field, old, new_val, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  char.location,
          details: {
            "mutation" => {
              "target_type" => "character",
              "target_id"   => char.id,
              "field"       => field,
              "old_value"   => old,
              "new_value"   => new_val
            }
          },
          participants: [ { character: char, role: "subject" } ]
        )
      end
    end
  end
end
