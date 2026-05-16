FactoryBot.define do
  factory :faction do
    sequence(:name) { |n| "Faction_#{n}" }
    subrole    { "thieves_guild" }
    is_kingdom { false }
  end
end
