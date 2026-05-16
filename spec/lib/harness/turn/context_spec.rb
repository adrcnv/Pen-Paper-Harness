require "rails_helper"

RSpec.describe Harness::Turn::Context do
  let(:tavern) { Location.create!(name: "Tavern") }
  let(:big)    { ->(_) { "big_response" } }
  let(:small)  { ->(_) { "small_response" } }

  describe "two-tier LLM seam" do
    it "wires both tiers when only llm_client is given (single-adapter setup)" do
      ctx = described_class.new(player_location: tavern, llm_client: big)
      expect(ctx.llm_grunt).to eq(big)
      expect(ctx.llm_nuance).to eq(big)
    end

    it "lets explicit tier args override llm_client at construction" do
      ctx = described_class.new(player_location: tavern, llm_client: big, llm_grunt: small)
      expect(ctx.llm_grunt).to eq(small)
      expect(ctx.llm_nuance).to eq(big)
    end

    it "accepts both tiers explicitly with no llm_client" do
      ctx = described_class.new(player_location: tavern, llm_grunt: small, llm_nuance: big)
      expect(ctx.llm_grunt).to eq(small)
      expect(ctx.llm_nuance).to eq(big)
    end

    it "back-compat: llm_client= sets both tiers" do
      ctx = described_class.new(player_location: tavern)
      ctx.llm_client = big
      expect(ctx.llm_grunt).to eq(big)
      expect(ctx.llm_nuance).to eq(big)
    end

    it "back-compat: llm_client reads grunt first, falls back to nuance" do
      ctx = described_class.new(player_location: tavern, llm_nuance: big)
      expect(ctx.llm_client).to eq(big)

      ctx.llm_grunt = small
      expect(ctx.llm_client).to eq(small)  # grunt wins
    end

    it "tiers are independently writable" do
      ctx = described_class.new(player_location: tavern)
      ctx.llm_grunt  = small
      ctx.llm_nuance = big
      expect(ctx.llm_grunt).to eq(small)
      expect(ctx.llm_nuance).to eq(big)
    end

    it "starts with both tiers nil when nothing is given" do
      ctx = described_class.new(player_location: tavern)
      expect(ctx.llm_grunt).to be_nil
      expect(ctx.llm_nuance).to be_nil
      expect(ctx.llm_client).to be_nil
    end
  end

  describe "Turn::Loop autowiring" do
    let(:adapter) { double("adapter", respond_to?: true) }
    let(:context) { described_class.new(player_location: tavern) }

    it "autowires both tiers from the adapter when neither is set" do
      allow(adapter).to receive(:respond_to?).with(:call).and_return(true)
      # Simulate Turn::Loop's autowire step:
      context.llm_grunt  ||= adapter
      context.llm_nuance ||= adapter
      expect(context.llm_grunt).to eq(adapter)
      expect(context.llm_nuance).to eq(adapter)
    end

    it "preserves a pre-configured grunt tier; only fills the unset one" do
      context.llm_grunt = small
      context.llm_grunt  ||= adapter
      context.llm_nuance ||= adapter
      expect(context.llm_grunt).to eq(small)     # preserved
      expect(context.llm_nuance).to eq(adapter)  # autowired
    end
  end
end
