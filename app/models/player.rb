class Player < Character
  # The player's current body. Singleton-ish — one row with type='Player'
  # at a time. On character death the player picks a new body (flip type
  # on the old row to something else or destroy; create a new Player row).
  #
  # Items, events, location, stats all work uniformly because they live on
  # the Character base.

  def self.instance
    first
  end
end
