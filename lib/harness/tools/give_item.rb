module Harness
  module Tools
    # Transfer an item from one character to another. Both must be at
    # the same location (no across-the-map handoffs). Use for gifts,
    # trades-in-kind, paying a smith with a found weapon, handing a
    # letter to a courier.
    #
    # For coin transfers, use transfer_coins. For dropping/picking up,
    # use drop/pickup.
    class GiveItem < Base
      def self.tool_name
        "give_item"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Transfer ownership of an item from one character to another. Both characters must be at the same location. The from_id must currently own the item. On success, item.character_id flips from from to to. A personal-scope event is logged with both as participants. Use for gifts, hand-offs, trades-in-kind. Use transfer_coins for money; use drop/pickup for floor interactions.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id" => { "type" => "integer", "description" => "id of the item being given" },
              "from_id" => { "type" => "integer", "description" => "current owner" },
              "to_id"   => { "type" => "integer", "description" => "recipient" },
              "reason"  => { "type" => "string",  "description" => "free text describing the handoff (e.g. 'a parting gift', 'payment in kind')" }
            },
            "required" => [ "item_id", "from_id", "to_id" ]
          }
        }
      end

      def call(args, context)
        item_id = args["item_id"]
        from_id = args["from_id"]
        to_id   = args["to_id"]
        reason  = args["reason"].is_a?(String) ? args["reason"].strip : ""

        return { "error" => "item_id required" } if item_id.nil?
        return { "error" => "from_id required" } if from_id.nil?
        return { "error" => "to_id required"   } if to_id.nil?
        return { "error" => "from_id and to_id must differ" } if from_id == to_id

        from = ::Character.find_by(id: from_id)
        return { "error" => "no character with id=#{from_id}" } unless from
        to   = ::Character.find_by(id: to_id)
        return { "error" => "no character with id=#{to_id}" }   unless to

        item = ::Item.find_by(id: item_id)
        return { "error" => "no item with id=#{item_id}" } unless item

        if item.character_id != from.id
          return { "error" => "from id=#{from_id} does not own item id=#{item_id} (owned by character_id=#{item.character_id || 'nobody'})" }
        end
        if from.location_id.nil? || from.location_id != to.location_id
          return { "error" => "from id=#{from_id} (loc=#{from.location_id}) and to id=#{to_id} (loc=#{to.location_id}) must be at the same location" }
        end

        item.update!(character_id: to.id)
        log_event(from, to, item, reason, context)

        {
          "item_id"     => item.id,
          "item_name"   => item.name,
          "from_id"     => from.id,
          "to_id"       => to.id,
          "reason"      => reason
        }
      end

      private

      def log_event(from, to, item, reason, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  from.location,
          details: {
            "give_item" => {
              "from_id"   => from.id,
              "to_id"     => to.id,
              "item_id"   => item.id,
              "item_name" => item.name,
              "reason"    => reason
            }
          },
          participants: [
            { character: from, role: "giver" },
            { character: to,   role: "recipient" }
          ]
        )
      end
    end
  end
end
