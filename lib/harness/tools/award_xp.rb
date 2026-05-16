module Harness
  module Tools
    # Grant XP to the PLAYER for a meaningful outcome — a problem solved,
    # an arc resolved, a notably-good roll that materially changed the
    # situation. Combat-kill XP is granted automatically by Tools::Resolve;
    # this tool is for everything else.
    #
    # Player-only by design. NPC XP isn't tracked — only the player levels.
    # Capped at MAX_PER_CALL to keep narrative awards from runaway-leveling
    # the player on a single creative description.
    #
    # Auto-levelup runs through XP::award! when the new total clears the
    # next threshold; the result is surfaced on the outcome.
    class AwardXP < Base
      MAX_PER_CALL = 50

      def self.tool_name
        "award_xp"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Grant XP to the PLAYER for a meaningful outcome — a problem solved, an arc resolved, a notably-good roll that materially changed the situation. Player-only (NPCs don't track XP). Amount is a positive integer; values above #{MAX_PER_CALL} are clamped. `reason` is short prose attributing the award. Auto-levels-up the player when the threshold clears, surfacing leveled_up + new_level + abilities_gained on the outcome. Combat-kill XP is granted automatically by `resolve` — do NOT use this tool to double-award for kills.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "character_id" => { "type" => "integer", "description" => "must be the player's character_id (INPUT.player.id); other ids are rejected" },
              "amount"       => { "type" => "integer", "description" => "positive integer; clamped to [1, #{MAX_PER_CALL}]" },
              "reason"       => { "type" => "string",  "description" => "short prose attributing the award (e.g. 'recovered the stolen patents', 'talked the rival captain down', 'solved Elder Harrow's missing-grandson arc')" }
            },
            "required" => [ "character_id", "amount", "reason" ]
          }
        }
      end

      def call(args, context)
        char_id = args["character_id"]
        amount  = args["amount"]
        reason  = args["reason"].is_a?(String) ? args["reason"].strip : ""

        return { "error" => "character_id required" } if char_id.nil?
        return { "error" => "amount must be a positive integer" } unless amount.is_a?(Integer) && amount.positive?
        return { "error" => "reason must be a non-empty string" } if reason.empty?

        char = ::Character.find_by(id: char_id)
        return { "error" => "no character with id=#{char_id}" } unless char
        return { "error" => "award_xp targets the player only; character_id=#{char_id} is type=#{char.type}" } unless char.is_a?(::Player)

        clamped = amount.clamp(1, MAX_PER_CALL)
        award   = ::Harness::Character::XP.award!(char, clamped)

        log_event(char, clamped, reason, context)

        {
          "character_id"      => char.id,
          "amount"            => clamped,
          "reason"            => reason,
          "xp_total"          => award[:total],
          "leveled_up"        => award[:levels_gained] > 0,
          "new_level"         => award[:levels_gained] > 0 ? award[:new_level] : nil,
          "abilities_gained"  => award[:abilities_gained].any? ? award[:abilities_gained].map { |a| a["name"] } : nil,
          "next_threshold"    => award[:next_threshold]
        }.compact
      end

      private

      def log_event(char, amount, reason, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0,
          scope:     "personal",
          location:  char.location,
          details: {
            "award_xp" => {
              "character_id" => char.id,
              "amount"       => amount,
              "reason"       => reason
            }
          },
          participants: [ { character: char, role: "actor" } ]
        )
      end
    end
  end
end
