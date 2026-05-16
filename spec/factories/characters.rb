FactoryBot.define do
  factory :character do
    sequence(:name) { |n| "Character_#{n}" }
    subrole { "villager" }
  end
end
