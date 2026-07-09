# Singleton row (see migration note): the session's cross-turn in-memory
# state, flushed at every turn boundary by Turn::Loop#persist_session_state!.
class SessionState < ApplicationRecord
  belongs_to :location, optional: true

  serialize :scene,   coder: JSON
  serialize :history, coder: JSON

  def self.current
    first
  end
end
