module Harness
  module Tools
    # Atomic coin transfer between two characters. Use for trade,
    # payment, bribery, looting a downed body, gifts. Coins live on the
    # `coins` integer column on characters — NOT as Item rows.
    #
    # Validation:
    #   - both ids must resolve to existing characters
    #   - amount must be a positive integer
    #   - from must have enough (clamped error, not silent partial)
    #   - from != to
    #
    # Side effects:
    #   - transactional update of both characters' coin columns
    #   - one personal-scope event with both as participants
    #     (from = "payer", to = "payee"; reason free text)
    class TransferCoins < Base
      def self.tool_name
        "transfer_coins"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Transfer coins from one character to another. Use for trade, payment, bribery, looting a corpse, gifts. Both characters must exist; amount must be a positive integer; from must have enough. The transfer is atomic — either both balances change or neither does. A personal-scope event is logged with both parties as participants. Coins are an integer column on characters; do NOT use mutate_character to move money — use this tool.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "from_id" => { "type" => "integer", "description" => "character paying" },
              "to_id"   => { "type" => "integer", "description" => "character receiving" },
              "amount"  => { "type" => "integer", "description" => "positive integer; will be rejected if from_id has less" },
              "reason"  => { "type" => "string",  "description" => "free text describing the transaction (e.g. 'paid for lodging', 'looted the corpse')" }
            },
            "required" => [ "from_id", "to_id", "amount" ]
          }
        }
      end

      def call(args, context)
        from_id = args["from_id"]
        to_id   = args["to_id"]
        amount  = args["amount"]
        reason  = args["reason"].is_a?(String) ? args["reason"].strip : ""

        return { "error" => "from_id required" } if from_id.nil?
        return { "error" => "to_id required"   } if to_id.nil?
        return { "error" => "amount must be a positive integer" } unless amount.is_a?(Integer) && amount.positive?
        return { "error" => "from_id and to_id must differ" }     if from_id == to_id

        from = ::Character.find_by(id: from_id)
        return { "error" => "no character with id=#{from_id}" } unless from
        to   = ::Character.find_by(id: to_id)
        return { "error" => "no character with id=#{to_id}"   } unless to

        if from.coins.to_i < amount
          return { "error" => "from_id=#{from_id} has only #{from.coins.to_i} coins; cannot transfer #{amount}" }
        end

        ::ActiveRecord::Base.transaction do
          from.update!(coins: from.coins - amount)
          to.update!(coins: to.coins + amount)
        end

        log_event(from, to, amount, reason, context)

        {
          "from_id"        => from.id,
          "to_id"          => to.id,
          "amount"         => amount,
          "from_balance"   => from.coins,
          "to_balance"     => to.coins,
          "reason"         => reason
        }
      end

      private

      def log_event(from, to, amount, reason, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  from.location || to.location,
          details: {
            "transfer_coins" => {
              "from_id" => from.id,
              "to_id"   => to.id,
              "amount"  => amount,
              "reason"  => reason
            }
          },
          participants: [
            { character: from, role: "payer" },
            { character: to,   role: "payee" }
          ]
        )
      end
    end
  end
end
