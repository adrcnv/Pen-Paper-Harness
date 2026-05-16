class Location < ApplicationRecord
  ALLOWED_TERRAINS   = %w[coast highland plains forest desert marsh mountain].freeze
  KINGDOM_ONLY_KINDS = %w[embassy garrison palace court barracks royal_residence].freeze

  belongs_to :parent,  class_name: "Location", optional: true
  belongs_to :faction, optional: true

  has_many :children, class_name: "Location", foreign_key: :parent_id, dependent: :nullify

  has_many :characters, dependent: :nullify
  has_many :items,      dependent: :nullify
  has_many :events,     dependent: :nullify
end
