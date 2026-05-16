FactoryBot.define do
  factory :item do
    sequence(:name) { |n| "Item_#{n}" }
    subrole { "mug" }
  end
end
