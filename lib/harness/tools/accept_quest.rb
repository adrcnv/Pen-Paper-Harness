module Harness
  module Tools
    # Reasoning-loop tool: the player has clearly agreed to take on a quest the
    # giver is offering. State changes:
    #
    #   quest.state: offered → active
    #   first pending step → active (opened_at_game_time = current)
    #
    # Discipline encoded in the schema description (reinforced by the reasoning
    # preamble): the LLM may only call this when (a) the quest's giver is in
    # the current scene's present_characters, AND (b) the player's intent to
    # accept is unambiguous. Ambiguous intent → don't call. Returns an error
    # otherwise so the reasoning loop sees the failure and reverts behavior.
    #
    # We also commit a forward acceptance event so future query_events surfaces
    # the moment the player took the contract.
    class AcceptQuest < Base
      def self.tool_name
        "accept_quest"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Move a quest from `offered` to `active` because the player has clearly agreed to take it on. ONLY call when (1) the quest's GIVER is currently in present_characters AND (2) the player's intent to accept is UNAMBIGUOUS (\"yes I'll find your shipment\", \"I'll take the job\"). Do NOT call on hedging (\"I'll think about it\"), curiosity (\"what's the pay?\"), or general engagement with the topic. The engine refuses to accept a quest whose giver isn't present. Commits a forward acceptance event tagging the player + giver as participants.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "quest_id" => { "type" => "integer", "description" => "Id of the quest to accept. From INPUT.active_quests or /quests output." }
            },
            "required" => [ "quest_id" ]
          }
        }
      end

      def call(args, context)
        quest_id = args["quest_id"]
        return { "error" => "quest_id must be an integer" } unless quest_id.is_a?(Integer)

        quest = ::Quest.find_by(id: quest_id)
        return { "error" => "no quest with id=#{quest_id}" } unless quest

        unless quest.state == "offered"
          return { "error" => "quest is in state=#{quest.state.inspect}; only `offered` quests can be accepted" }
        end

        player = ::Player.first
        return { "error" => "no player row exists" } unless player

        giver = quest.giver
        return { "error" => "quest giver no longer exists" } unless giver

        scene = context.active_scene
        present_ids = scene ? scene.present_characters.map(&:id).to_set : ::Set.new
        unless present_ids.include?(giver.id)
          return { "error" => "quest giver (#{giver.name}, id=#{giver.id}) is not in present_characters; the player must be talking to them face-to-face to accept this quest" }
        end

        first_step = quest.quest_steps.where(state: "pending").order(:position).first
        return { "error" => "quest has no pending steps" } unless first_step

        gt = context.game_time || 0

        accept_event = ::ActiveRecord::Base.transaction do
          quest.update!(state: "active")
          first_step.update!(state: "active", opened_at_game_time: gt)

          ::Harness::Event::ForwardAppender.append(
            game_time: gt,
            scope:     "personal",
            location:  giver.location || context.player_location,
            details: {
              "summary"   => "Accepted quest \"#{quest.name}\"",
              "narrative" => "#{player.name} accepted #{giver.name}'s request: #{quest.summary}",
              "quest" => {
                "quest_id"     => quest.id,
                "archetype_id" => quest.archetype_id,
                "accepted"     => true
              }
            },
            participants: [
              { character: player, role: "actor" },
              { character: giver,  role: "quest_giver" }
            ]
          )
        end

        {
          "quest_id"          => quest.id,
          "name"              => quest.name,
          "state"             => quest.state,
          "current_step_id"   => first_step.id,
          "current_step_pos"  => first_step.position,
          "current_step_desc" => first_step.description,
          "event_id"          => accept_event.id,
          "game_time"         => gt
        }
      end
    end
  end
end
