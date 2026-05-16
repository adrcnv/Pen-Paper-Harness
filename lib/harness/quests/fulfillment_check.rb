module Harness
  module Quests
    # Pure Ruby end-of-turn pass. For each active Quest, check if its current
    # `active` step is fulfilled by world state. If so, mark it fulfilled and
    # promote the next pending step. If no pending step remains, mark the
    # quest complete.
    #
    # Fulfillment is STRUCTURAL only — the LLM never marks steps complete.
    # Same philosophy as Phase 2: anything verifiable is verified by the
    # engine, not by the model.
    #
    # Idempotent — safe to re-run; a fulfilled step stays fulfilled.
    #
    # See QUESTS_DESIGN.md for the fulfillment-kind enum.
    module FulfillmentCheck
      class << self
        def run!(context, logger: ::Rails.logger)
          player = ::Player.first
          return unless player

          ::Quest.where(state: "active").includes(:quest_steps).find_each do |quest|
            active = quest.quest_steps.where(state: "active").order(:position).first
            next unless active
            next unless step_fulfilled?(active, player)

            advance!(quest, active, context, logger)
          end
        end

        private

        def step_fulfilled?(step, player)
          case step.fulfillment_kind
          when "information"
            return false unless step.target_character_id
            return false unless step.opened_at_game_time
            ::Event.joins(:event_participants)
              .where(event_participants: { character_id: step.target_character_id })
              .where(id: ::EventParticipant.where(character_id: player.id).select(:event_id))
              .where("events.game_time > ?", step.opened_at_game_time)
              .exists?
          when "item_in_inventory"
            return false unless step.target_item_id
            ::Item.where(id: step.target_item_id, character_id: player.id).exists?
          when "character_dead"
            return false unless step.target_character_id
            target = ::Character.find_by(id: step.target_character_id)
            return false unless target
            target.max_hp.to_i > 0 && target.current_hp.to_i <= 0
          when "character_at_location"
            return false unless step.target_character_id && step.target_location_id
            ::Character.where(id: step.target_character_id, location_id: step.target_location_id).exists?
          else
            false
          end
        end

        def advance!(quest, active_step, context, logger)
          ::ActiveRecord::Base.transaction do
            active_step.update!(
              state:                  "fulfilled",
              fulfilled_at_game_time: context.game_time || 0
            )
            nxt = quest.quest_steps.where(state: "pending").order(:position).first
            if nxt
              nxt.update!(state: "active", opened_at_game_time: context.game_time || 0)
              logger.info { "[Quest::FulfillmentCheck] quest=#{quest.id} step #{active_step.position} fulfilled; promoting step #{nxt.position}" }
            else
              quest.update!(state: "complete")
              logger.info { "[Quest::FulfillmentCheck] quest=#{quest.id} #{quest.name.inspect} complete" }
            end
          end
        end
      end
    end
  end
end
