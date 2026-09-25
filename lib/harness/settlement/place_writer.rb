module Harness
  module Settlement
    # ONE door for a place spoken of or asked about. Three writers used to
    # coin places on their own rules (the worldbuilding runner, the person
    # realizer's anchor, the place realizer), and a poor hamlet ended a
    # session with three smithies and two taprooms, none of them consulting
    # the manifest that had laid the town out (2026-09-22).
    #
    # Routing, mechanical:
    #   1. an existing row by name (article/case-insensitive): the
    #      settlement's own rows and itself first, then a settlement
    #      anywhere → link
    #   2. the bind judge: which listed room is it, or which scenery kind,
    #      or neither → link / mint once / refuse
    # A refusal is the manifest gate by construction: a room the settlement
    # was not laid out with cannot be talked into existence. The only judged
    # question is "which of these is it" — an id judge at zero temperature.
    module PlaceWriter
      PROMPT_PATH = Rails.root.join("lib/harness/prompts/place_bind.txt")

      # key: the scenery kind minted or linked; for :person — no place, an
      # ask for someone by name (the worldbuilding runner's business) — the
      # name.
      Result = Struct.new(:location, :status, :key, keyword_init: true) do
        def linked?  = status == :linked
        def minted?  = status == :minted
        def refused? = %i[refused person].include?(status)
      end
      REFUSED = Result.new(location: nil, status: :refused, key: nil).freeze

      BIND_SCHEMA = {
        "type" => "object",
        "properties" => {
          "reasoning" => { "type" => "string" },
          "is"        => { "type" => "string", "enum" => %w[listed_room scenery person neither] },
          "room_id"   => { "type" => %w[integer null] },
          "scenery"   => { "anyOf" => [ { "type" => "null" }, { "type" => "string", "enum" => Scenery.keys } ] },
          "person"    => { "type" => %w[string null] }
        },
        "required" => %w[reasoning is room_id scenery person],
        "additionalProperties" => false
      }.freeze

      module_function

      # name    : the place as spoken or asked for
      # about   : what was said of it (may be nil)
      # source  : :claim (an NPC's sentence) | :ask (the player's question) — for the log
      # context : Turn::Context (player_location, llm_grunt)
      def resolve(name:, context:, about: nil, source: :claim, logger: Rails.logger)
        nm = name.to_s.strip
        return REFUSED if nm.empty?
        settlement = root_of(context.player_location)
        return REFUSED unless settlement

        if (row = existing(nm, settlement))
          logger.info { "[Settlement::PlaceWriter] #{source} #{nm.inspect} LINKS #{row.name.inspect} (##{row.id}) by name" }
          return Result.new(location: row, status: :linked, key: nil)
        end

        rooms = ::Location.where(parent_id: settlement.id).order(:id).to_a
        bind  = bind(nm, about, settlement, rooms, context, logger)
        case bind && bind["is"]
        when "listed_room"
          id  = bind["room_id"].to_i
          row = ([ settlement ] + rooms).find { |l| l.id == id }
          if row
            logger.info { "[Settlement::PlaceWriter] #{source} #{nm.inspect} LINKS #{row.name.inspect} (##{row.id}) by the bind judge" }
            return Result.new(location: row, status: :linked, key: nil)
          end
          logger.info { "[Settlement::PlaceWriter] #{source} #{nm.inspect}: the bind judge named ##{id}, not listed — refused" }
        when "scenery"
          loc, minted = Scenery.find_or_mint!(settlement: settlement, key: bind["scenery"], logger: logger)
          if loc
            logger.info { "[Settlement::PlaceWriter] #{source} #{nm.inspect} is scenery #{bind['scenery']} → #{minted ? 'MINTED' : 'links'} #{loc.name.inspect} (##{loc.id})" }
            return Result.new(location: loc, status: (minted ? :minted : :linked), key: bind["scenery"])
          end
        when "person"
          key = bind["person"].to_s.strip
          unless key.empty?
            logger.info { "[Settlement::PlaceWriter] #{source} #{nm.inspect} asks for a person: #{key.inspect}" }
            return Result.new(location: nil, status: :person, key: key)
          end
        end
        logger.info { "[Settlement::PlaceWriter] #{source} #{nm.inspect} refused: #{bind ? bind['reasoning'].to_s[0, 80].inspect : 'no bind'}" }
        REFUSED
      rescue ::StandardError => e
        logger.warn { "[Settlement::PlaceWriter] failed for #{name.inspect}: #{e.class}: #{e.message}" }
        REFUSED
      end

      def root_of(location)
        loc = location
        loc = loc.parent while loc&.parent
        loc
      end

      # Article/case-insensitive. The settlement's own rows and itself first;
      # then only a settlement ROOT anywhere (a claim about another town links
      # to that town — never to another town's alehouse by a generic name).
      def existing(nm, settlement)
        variants = ::Location.name_variants(nm)
        pick     = ->(rows) { rows.find { |l| l.name.casecmp?(nm) } || rows.first }
        local    = ::Location.where("LOWER(name) IN (?)", variants).where("parent_id = ? OR id = ?", settlement.id, settlement.id).to_a
        pick.call(local) || pick.call(::Location.where("LOWER(name) IN (?)", variants).where(parent_id: nil).to_a)
      end

      def bind(nm, about, settlement, rooms, context, logger)
        llm = context.llm_grunt
        return nil unless llm
        payload = {
          "spoken"     => { "name" => nm, "about" => about.to_s.strip.presence }.compact,
          "settlement" => { "id" => settlement.id, "name" => settlement.name },
          "rooms"      => rooms.map { |l| { "id" => l.id, "name" => l.name, "about" => l.description.to_s } },
          "scenery"    => Scenery.specs.map { |s| { "key" => s.key, "is" => s.gloss } }
        }
        raw = ::Harness::CostTracker.in_subsystem(:place_bind) do
          llm.complete(system: preamble, user: "INPUT:\n#{JSON.pretty_generate(payload)}",
                       schema: BIND_SCHEMA, max_tokens: 256, temperature: 0, thinking: false)
        end
        parsed = ::Harness::LLM::JsonResponse.parse(raw)
        logger.debug { "[Settlement::PlaceWriter] bind #{nm.inspect} → #{parsed.inspect[0, 200]}" }
        parsed.is_a?(::Hash) ? parsed : nil
      end

      def preamble
        @preamble ||= File.read(PROMPT_PATH)
      end
    end
  end
end
