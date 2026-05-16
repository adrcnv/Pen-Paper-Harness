require "rails_helper"

RSpec.describe Harness::Resolver do
  let(:location) { Location.create!(name: "Tavern") }
  let(:context)  { Harness::Turn::Context.new(player_location: location) }

  describe "#execute" do
    it "dispatches a known tool and returns its result" do
      maren = Npc.create!(name: "Maren", subrole: "barkeep", location: location)
      call = Harness::LLM::ToolCall.new(name: "query_character", args: { "character_id" => maren.id })

      result = described_class.new(context: context).execute(call)
      expect(result).to include("id" => maren.id, "name" => "Maren")
    end

    it "returns {error:} for unknown tools rather than raising" do
      call = Harness::LLM::ToolCall.new(name: "hack_the_gibson", args: {})
      result = described_class.new(context: context).execute(call)
      expect(result["error"]).to match(/unknown tool/)
    end

    it "catches exceptions inside tools and wraps them as {error:}" do
      bad_tool = Class.new(Harness::Tools::Base) do
        def self.tool_name
          "bad"
        end
        def self.schema
          { "name" => "bad", "description" => "", "input_schema" => { "type" => "object", "properties" => {}, "required" => [] } }
        end
        def call(_args, _context)
          raise "kaboom"
        end
      end

      call = Harness::LLM::ToolCall.new(name: "bad", args: {})
      result = described_class.new(context: context, tools: [ bad_tool ]).execute(call)
      expect(result["error"]).to match(/kaboom/)
    end

    it "exposes schemas for whichever tool set it was given" do
      resolver = described_class.new(context: context, tools: [ Harness::Tools::QueryScene ])
      expect(resolver.schemas.map { |s| s["name"] }).to eq([ "query_scene" ])
    end

    describe "XML tool-call leak guard" do
      let(:maren) { Npc.create!(name: "Maren", subrole: "barkeep", location: location) }

      it "rejects calls whose top-level string arg contains <parameter ...> syntax" do
        call = Harness::LLM::ToolCall.new(
          name: "propose_event",
          args: { "scope" => "local", "trigger" => "x", "details" => "stuff happened\",<parameter name=\"game_time\">99000" }
        )
        result = described_class.new(context: context).execute(call)
        expect(result["error"]).to match(/XML tool-call syntax.*'details'/)
      end

      it "rejects calls whose nested string arg contains antml:parameter" do
        call = Harness::LLM::ToolCall.new(
          name: "propose_character",
          args: {
            "name" => "Marta",
            "subrole" => "brewer",
            "connection" => "antml:parameter>foo<parameter name=\"location_id\">3"
          }
        )
        result = described_class.new(context: context).execute(call)
        expect(result["error"]).to match(/XML tool-call syntax.*'connection'/)
      end

      it "rejects calls with the leak inside an array of objects" do
        call = Harness::LLM::ToolCall.new(
          name: "propose_event",
          args: {
            "scope" => "local",
            "trigger" => "x",
            "participants" => [ { "character_id" => maren.id, "role" => "actor</parameter>" } ]
          }
        )
        result = described_class.new(context: context).execute(call)
        expect(result["error"]).to match(/XML tool-call syntax.*'participants\[0\]\.role'/)
      end

      it "passes through clean string args without false positives" do
        call = Harness::LLM::ToolCall.new(
          name: "propose_event",
          args: { "scope" => "local", "trigger" => "x", "details" => "Two patrons quarreled over a debt; the matter was settled in the alley." }
        )
        result = described_class.new(context: context).execute(call)
        expect(result["error"]).to be_nil
        expect(result["event_id"]).to be_present
      end
    end
  end

  describe ".tools_for" do
    it "returns DEFAULT_TOOLS when no active scene" do
      ctx = Harness::Turn::Context.new(player_location: location)
      expect(Harness::Resolver.tools_for(ctx)).to eq(Harness::Resolver::DEFAULT_TOOLS)
    end

    it "returns DEFAULT_TOOLS when scene is not in combat" do
      ctx = Harness::Turn::Context.new(player_location: location)
      ctx.active_scene = Harness::Scene::Active.new(
        location: location, snapshot: nil, narrations: [], internal_state: {}, agendas: {},
        extras: [], entered_at_game_time: 0
      )
      expect(Harness::Resolver.tools_for(ctx)).to eq(Harness::Resolver::DEFAULT_TOOLS)
    end

    it "returns COMBAT_TOOLS when scene is in combat" do
      ctx = Harness::Turn::Context.new(player_location: location)
      ctx.active_scene = Harness::Scene::Active.new(
        location: location, snapshot: nil, narrations: [], internal_state: {}, agendas: {},
        extras: [], entered_at_game_time: 0
      )
      ctx.active_scene.start_combat!
      expect(Harness::Resolver.tools_for(ctx)).to eq(Harness::Resolver::COMBAT_TOOLS)
    end

    it "passes the supplied normal_tools registry through when not in combat" do
      ctx = Harness::Turn::Context.new(player_location: location)
      custom = [ Harness::Tools::QueryScene ]
      expect(Harness::Resolver.tools_for(ctx, normal_tools: custom)).to eq(custom)
    end
  end

  describe "registry contents" do
    it "DEFAULT_TOOLS includes start_combat (entry into combat mode)" do
      expect(Harness::Resolver::DEFAULT_TOOLS).to include(Harness::Combat::Tools::StartCombat)
    end

    it "COMBAT_TOOLS excludes transitions, propose_*, and the bulk of queries" do
      names = Harness::Resolver::COMBAT_TOOLS.map(&:tool_name)
      expect(names).to include("query_scene", "resolve", "mutate_character", "propose_event")
      expect(names).to include("move_to", "end_turn")
      expect(names).not_to include("transition", "travel", "pass_time")
      expect(names).not_to include("propose_character", "propose_faction", "propose_location", "propose_item")
      expect(names).not_to include("query_character", "query_events", "query_faction", "query_item")
      expect(names).not_to include("start_combat") # already in combat
    end
  end
end
