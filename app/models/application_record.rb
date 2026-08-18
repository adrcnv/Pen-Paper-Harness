class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Turn flight recorder taps (Harness::Turn::Receipt) — no-ops unless a
  # turn ledger is open. update_column bypasses these by design (cache
  # writes stay invisible to the receipt).
  after_create  { ::Harness::Turn::Receipt.record_write(self, :create) }
  after_update  { ::Harness::Turn::Receipt.record_write(self, :update) }
  after_destroy { ::Harness::Turn::Receipt.record_write(self, :destroy) }
end
