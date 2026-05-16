module Harness
  module Tools
    class MutateItem < Base
      COLUMN_FIELDS   = %w[name subrole location_id character_id].freeze
      RESERVED_FIELDS = %w[id created_at updated_at properties].freeze

      def self.tool_name
        "mutate_item"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Change one attribute of an item. `field` is either a column (name, subrole, location_id, character_id) or a free-form property key (enchantment, condition, description, ...). Setting location_id or character_id automatically clears the other — an item is either anchored to a place or held by someone, never both. Use character_id=N + value=null together semantics: setting character_id to a character_id picks up the item; setting location_id to a location picks up a dropped item or places one. Property values are free-form; null deletes.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id" => { "type" => "integer" },
              "field"   => { "type" => "string" },
              "value"   => { "description" => "new value; null on location_id/character_id unsets, null on a property key deletes it" }
            },
            "required" => [ "item_id", "field" ]
          }
        }
      end

      def call(args, context)
        id    = args["item_id"]
        field = args["field"]
        value = args["value"]

        return { "error" => "item_id required" } if id.nil?
        return { "error" => "field must be a non-empty string" } unless field.is_a?(String) && !field.strip.empty?
        return { "error" => "#{field} is a reserved field and cannot be mutated" } if RESERVED_FIELDS.include?(field)

        item = ::Item.find_by(id: id)
        return { "error" => "no item with id=#{id}" } unless item

        result = if COLUMN_FIELDS.include?(field)
          update_column(item, field, value)
        else
          merge_property(item, field, value)
        end

        return result if result["error"]

        log_event(item, field, result["old_value"], result["new_value"], context)
        result.merge("id" => item.id, "field" => field)
      end

      private

      def update_column(item, field, value)
        case field
        when "name"
          return { "error" => "name must be a non-empty string" } unless value.is_a?(String) && !value.strip.empty?
          apply_simple(item, field, value)
        when "subrole"
          return { "error" => "subrole must be a string" } unless value.is_a?(String)
          apply_simple(item, field, value)
        when "location_id"
          return move_to_location(item, value)
        when "character_id"
          return move_to_character(item, value)
        end
      end

      def apply_simple(item, field, value)
        old = item.read_attribute(field)
        item.update!(field => value)
        { "old_value" => old, "new_value" => value }
      end

      # Moving to a location clears character_id (item is now on the floor).
      # Null is not accepted — an item always has either a location or a holder.
      # Destruction is a future tool; mutate_item cannot orphan.
      def move_to_location(item, value)
        return { "error" => "location_id must be a non-null integer (destruction is a separate operation)" } unless value.is_a?(Integer)
        return { "error" => "no location with id=#{value}" } unless ::Location.exists?(id: value)

        old = { "location_id" => item.location_id, "character_id" => item.character_id }
        item.update!(location_id: value, character_id: nil)
        { "old_value" => old, "new_value" => { "location_id" => value, "character_id" => nil } }
      end

      # Moving to a character clears location_id (item is now in inventory).
      # Null is not accepted — use location_id to drop into the world instead.
      def move_to_character(item, value)
        return { "error" => "character_id must be a non-null integer (use location_id to drop)" } unless value.is_a?(Integer)
        return { "error" => "no character with id=#{value}" } unless ::Character.exists?(id: value)

        old = { "location_id" => item.location_id, "character_id" => item.character_id }
        item.update!(character_id: value, location_id: nil)
        { "old_value" => old, "new_value" => { "location_id" => nil, "character_id" => value } }
      end

      def merge_property(item, field, value)
        props = (item.properties || {}).dup
        old   = props[field]
        if value.nil?
          props.delete(field)
        else
          props[field] = value
        end
        item.update!(properties: props)
        { "old_value" => old, "new_value" => value }
      end

      def log_event(item, field, old, new_val, context)
        # Event location is where the item physically ends up — the character's
        # location if now held, or the item's location if anchored. Participant
        # is the holder if a character now owns it.
        holder = item.character_id ? ::Character.find_by(id: item.character_id) : nil
        event_loc = holder&.location || item.location

        participants = holder ? [ { character: holder, role: "holder" } ] : []

        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  event_loc,
          details: {
            "mutation" => {
              "target_type" => "item",
              "target_id"   => item.id,
              "target_name" => item.name,
              "field"       => field,
              "old_value"   => old,
              "new_value"   => new_val
            }
          },
          participants: participants
        )
      end
    end
  end
end
