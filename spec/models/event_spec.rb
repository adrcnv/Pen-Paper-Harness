require 'rails_helper'

RSpec.describe Event, type: :model do
  describe "#recall_text vs #embed_text (display vs ranker contract)" do
    it "keeps the trigger framing for display but embeds substance only" do
      e = Event.new(details: { "narrative" => { "trigger" => "overheard", "details" => "Ingvar owes forty marks." } })
      expect(e.recall_text).to eq("overheard — Ingvar owes forty marks.")
      expect(e.embed_text).to eq("Ingvar owes forty marks.")
      expect(e.content).to eq(e.embed_text) # CosineRanker embeds via #content
    end

    it "falls back to the trigger when the narrative has no details" do
      e = Event.new(details: { "narrative" => { "trigger" => "a brawl broke out" } })
      expect(e.embed_text).to eq("a brawl broke out")
    end

    it "uses the summary for genesis/catch-up shaped details" do
      e = Event.new(details: { "summary" => "Aelorin Greymantle negotiates a trade pact." })
      expect(e.embed_text).to eq("Aelorin Greymantle negotiates a trade pact.")
      expect(e.recall_text).to eq("Aelorin Greymantle negotiates a trade pact.")
    end
  end
end
