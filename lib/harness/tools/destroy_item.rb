module Harness
  module Tools
    # Remove an Item from the world permanently. The botch teeth for acts
    # that rework an item (a critically failed mend wrecks the shield), and
    # the future consumer for burning/consuming. Logs a personal-scope
    # destruction event; after this the row is gone from every sheet and
    # scene — mutate_item deliberately cannot orphan, this is the one door.
    class DestroyItem < Base
      def self.tool_name
        "destroy_item"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Destroy an item permanently — it is removed from the world (inventory or scene). Use only when the fiction has genuinely wrecked or consumed it; damage that leaves wreckage behind is mutate_item, not destruction.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id" => { "type" => "integer" },
              "reason"  => { "type" => "string", "description" => "short free-text cause of the destruction" }
            },
            "required" => [ "item_id" ]
          }
        }
      end

      def call(args, context)
        id = args["item_id"]
        return { "error" => "item_id required" } if id.nil?
        item = ::Item.find_by(id: id)
        return { "error" => "no item with id=#{id}" } unless item

        holder    = item.character_id ? ::Character.find_by(id: item.character_id) : nil
        event_loc = holder&.location || item.location
        name      = item.name
        item.destroy!

        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  event_loc,
          details: {
            "destruction" => {
              "target_type" => "item",
              "target_id"   => id,
              "target_name" => name,
              "reason"      => args["reason"].to_s.strip.presence
            }.compact
          },
          participants: holder ? [ { character: holder, role: "holder" } ] : []
        )

        { "item_id" => id, "item_name" => name, "destroyed" => true }
      end
    end
  end
end
