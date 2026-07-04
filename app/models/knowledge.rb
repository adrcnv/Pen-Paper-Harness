# A standing, faceted fact about the world. See CreateKnowledge migration and
# Harness::Knowledge::Query (the read primitive). Table is uncountable, so the
# name is pinned rather than pluralized to "knowledges".
class Knowledge < ApplicationRecord
  self.table_name = "knowledge"

  belongs_to :location, optional: true

  scope :current, -> { where(current: true) }
end
