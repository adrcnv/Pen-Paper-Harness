class Journey < ApplicationRecord
  belongs_to :destination, class_name: "Location"

  # Singleton-ish: one active journey at a time. We treat the table as a
  # cache of "where the player is currently traveling to," not as a history.
  # Starting a journey to a different destination overwrites the existing
  # row (see `Journey.start_or_replace`).
  def self.active
    order(id: :desc).first
  end

  # Idempotent on (destination, origin coords). If an active journey to the
  # same destination exists, return it (resume). Otherwise wipe + create
  # fresh.
  def self.start_or_replace(destination:, origin_x:, origin_y:, started_at_game_time:)
    existing = active
    if existing && existing.destination_id == destination.id
      return existing
    end
    transaction do
      delete_all
      create!(
        destination:          destination,
        origin_x:             origin_x,
        origin_y:             origin_y,
        cursor_x:             origin_x,
        cursor_y:             origin_y,
        started_at_game_time: started_at_game_time,
        elapsed_minutes:      0
      )
    end
  end

  # Distance still to go from cursor → destination, raw euclidean. The
  # caller multiplies by terrain to get minutes.
  def remaining_distance
    Math.hypot(destination.x - cursor_x, destination.y - cursor_y)
  end
end
