module Harness
  module Scene
    # "Those with appointments get drawn always": entering a location where
    # an open meet with the player falls due (early by LEAD, late within the
    # breach grace) relocates the counterparty here — the one draw that is a
    # certainty, not a dice roll. The meeting place is the location the deal
    # was STRUCK at (the schema's only place column) — right for "meet me
    # here tomorrow", wrong for a meeting arranged for elsewhere; a
    # spoken-where field on deals can refine that later. Pure relocation of
    # an existing row; the Evictor sends them home afterwards as usual.
    class AppointmentPin
      LEAD = 120

      def self.pin!(location, game_time, logger: Rails.logger)
        return [] unless location && game_time
        player = ::Player.first
        return [] unless player

        now = game_time.to_i
        window = (now - ::Obligation::BREACH_GRACE)..(now + LEAD)
        ::Obligation.open_now.where(kind: "meet", location_id: location.id)
          .involving(player.id).where(due_time: window)
          .filter_map do |ob|
            other_id = ob.debtor_id == player.id ? ob.creditor_id : ob.debtor_id
            npc = ::Npc.find_by(id: other_id)
            next if npc.nil? || npc.location_id == location.id
            next if npc.max_hp.to_i.positive? && npc.current_hp.to_i <= 0 # dead keep no appointments
            npc.update!(location_id: location.id)
            logger.info { "[Scene::AppointmentPin] #{npc.name} waits at #{location.name} (meet ##{ob.id}, due t=#{ob.due_time})" }
            npc
          end
      rescue ::StandardError => e
        logger.warn { "[Scene::AppointmentPin] failed (non-fatal): #{e.class}: #{e.message}" }
        []
      end
    end
  end
end
