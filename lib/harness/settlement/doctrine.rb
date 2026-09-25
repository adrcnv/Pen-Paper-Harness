module Harness
  module Settlement
    # The town's own composition as standing local knowledge: which trades
    # and offices it has, who holds them, and which it lacks. Written from
    # rows, no LLM, rewritten only when the rows changed. Genesis already
    # mirrors the founding history into knowledge because "the town at
    # large knows the story" is doctrine by scope; nothing did the same for
    # the town's shape, so every voice knew how Crowstead was founded and
    # none knew it had no magistrate — and a patron in the alehouse could
    # call himself one (deeds-1). One fact per office held and one per
    # office lacked, anchored at the root so Query serves them in every
    # room; recall finds the smith's on "is there a smith" because the
    # trade is named, and only that one — a single roster fact came back
    # as a recited list (roster-1).
    #
    # Everything here matches TRADES exactly — the manifest's closed
    # vocabulary, which the reflection judge already chooses a claimed
    # person's trade from and the materializer's cast is validated against.
    # No synonyms, no parsing of what was said: the leap from words to a
    # trade is the model's, made upstream (ruling 2026-09-24).
    #
    # The same rows answer a claimed person's trade with the town's holder
    # (`holder`): the offices half of the person door.
    module Doctrine
      SOURCE = "layout".freeze

      # How folk say an office where the manifest's word is not how a
      # player asks. Display only.
      WORDS = { "reeve" => "reeve or magistrate", "guard" => "guard or watch" }.freeze

      Holder = Struct.new(:npc, :status, :trade, keyword_init: true) do
        def linked? = status == :linked
        def absent? = status == :absent
        def words   = WORDS.fetch(trade, trade.to_s.tr("_", " "))
      end

      module_function

      # The civic offices — the manifest's universal, size- and wealth-gated
      # rooms' trades. A settlement HAS one when a room carries the trade or
      # a living resident's trade is it; it LACKS one otherwise, and says so.
      def civic = Manifest.civic_subroles

      # Civic offices held by one person: a second reeve is a twin, a second
      # guard is a watch.
      def unique = Manifest.civic_subroles - Manifest.crew_subroles

      # Recompute the settlement's facts from rows and persist what changed:
      # a fact no longer true has its row retired (current: false), a new
      # one is written. A row a reflection has since revised (a voice's
      # "healing is sought inland" merged onto it under its own source) stands
      # while the rows behind it hold — rewriting it every entry would revert
      # the revision each time. Returns the current rows, or nil for a place
      # that is no settlement. Non-fatal.
      def refresh!(location, game_time: 0, logger: Rails.logger)
        root = root_of(location)
        return nil unless root && root.settlement?
        wanted  = compose(root)
        rows    = ::Knowledge.where(source_kind: SOURCE, location_id: root.id).order(:id).to_a
        heads   = rows.group_by(&:content).transform_values { |rs| head_of(rs.last) }

        retired = heads.reject { |content, _| wanted.include?(content) }.values.select(&:current)
        retired.each { |k| k.update!(current: false) }
        written = wanted.reject { |content| heads[content]&.current }.map do |content|
          ::Knowledge.create!(content: content, location_id: root.id, current: true, source_kind: SOURCE, game_time: game_time.to_i)
        end
        if retired.any? || written.any?
          logger.info { "[Settlement::Doctrine] #{root.name}: #{written.size} fact(s) written, #{retired.size} retired: #{written.map(&:content).join(' ')[0, 200]}" }
        end
        wanted.map { |content| heads[content]&.current ? heads[content] : written.find { |k| k.content == content } }
      rescue ::StandardError => e
        logger.warn { "[Settlement::Doctrine] failed for #{location&.name}: #{e.class}: #{e.message}" }
        nil
      end

      def root_of(location)
        loc = location
        loc = loc.parent while loc&.parent
        loc
      end

      # The newest row of a supersedes chain (a reflection's revision of a
      # layout row is a conversation row pointing back at it).
      def head_of(row)
        loop do
          nxt = ::Knowledge.where(supersedes_id: row.id).order(:id).last
          return row unless nxt
          row = nxt
        end
      end

      # ["Saltmere's barkeep is Eir Leifson, at the Alehouse.",
      #  "Saltmere's smith is at the Smithy.", "Saltmere's moneylender is Wynflaed.",
      #  "Saltmere has no reeve or magistrate.", "Saltmere has no guard or watch."]
      def compose(root)
        residents = living_residents(root)
        facts     = []
        covered   = []
        rooms_of(root).each do |room|
          trade = trade_of(room)
          next if trade.empty?
          keeper = keeper_of(room, residents)
          facts << "#{root.name}'s #{say(trade)} is #{keeper ? "#{keeper.name}, " : ''}at #{room.name}."
          covered << trade
        end
        (civic - covered).each do |trade|
          holders = residents.select { |c| c.subrole == trade }
          next if holders.empty?
          facts << "#{root.name}'s #{say(trade)} is #{holders.map(&:name).join(' and ')}."
          covered << trade
        end
        # One row per absence too: a hamlet's ten absences in one sentence
        # came back recited whole to "is there a smith" (roster-3).
        (civic - covered).each { |trade| facts << "#{root.name} has no #{WORDS.fetch(trade, say(trade))}." }
        facts
      end

      # A claimed person's trade against the town's rows. The keeper of the
      # room the claim anchors to, when that room carries the trade (seeded
      # now if it stands empty) — "the salter out at the Flats". Else, for a
      # unique civic office: the room that carries it, a resident who holds
      # it, or ABSENT. nil for any other trade: the Realizer's business.
      def holder(trade, location, anchor: nil, llm: nil, logger: Rails.logger)
        trade = trade.to_s
        root  = root_of(location)
        return nil unless root && root.settlement? && !trade.empty?
        residents = living_residents(root)
        if anchor && anchor.parent_id == root.id && trade_of(anchor) == trade
          keeper = keeper_of(anchor, residents) || (llm && ::Harness::Scene::StaffSeeder.ensure!(anchor, llm: llm, logger: logger))
          return Holder.new(npc: keeper, status: :linked, trade: trade) if keeper
        end
        return nil unless unique.include?(trade)
        if (room = rooms_of(root).find { |r| trade_of(r) == trade })
          keeper = keeper_of(room, residents) || (llm && ::Harness::Scene::StaffSeeder.ensure!(room, llm: llm, logger: logger))
          return Holder.new(npc: keeper, status: :linked, trade: trade) if keeper
        end
        if (npc = residents.find { |c| c.subrole == trade })
          return Holder.new(npc: npc, status: :linked, trade: trade)
        end
        Holder.new(npc: nil, status: :absent, trade: trade)
      end

      # Is this trade a unique office someone in the town already holds? The
      # materializer's cast must not seat a second reeve beside the hall's
      # keeper (roster-1: a woken founder recast as reeve, two reeves named
      # by different townsfolk).
      def office_held?(trade, location)
        trade = trade.to_s
        return false unless unique.include?(trade)
        root = root_of(location)
        return false unless root && root.settlement?
        residents = living_residents(root)
        rooms_of(root).any? { |r| trade_of(r) == trade && keeper_of(r, residents) } ||
          residents.any? { |c| c.subrole == trade }
      end

      def say(trade) = trade.to_s.tr("_", " ")

      def rooms_of(root) = ::Location.where(parent_id: root.id).order(:id).to_a

      def trade_of(room) = room.properties.is_a?(::Hash) ? room.properties["trade"].to_s : ""

      def keeper_of(room, residents) = residents.find { |c| c.home_location_id == room.id }

      # Living, awake people anchored anywhere in the settlement.
      def living_residents(root)
        ::Npc.where(home_location_id: ::Harness::Scene::Residents.ancestry_ids(root)).to_a
             .reject { |c| ::Harness::Scene::Residents.dormant?(c) || ::Harness::Scene::Residents.deceased?(c) }
      end
    end
  end
end
