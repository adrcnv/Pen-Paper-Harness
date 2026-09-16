require "yaml"

module Harness
  module Items
    # Materialisation on a character's word. A thing an NPC offers or hands
    # over in conversation becomes a row the moment the beat lands — on the
    # table (anchored here, for sale, seller recorded) or in the recipient's
    # hands — so the next turn's take, buy or refusal binds against something
    # real instead of narrating a phantom (items probe run-20260913-212815:
    # every NPC-mediated hand-off was words).
    #
    # Three gates, all mechanical, none of them prompt text:
    #   1. the trade — the category must be one the character's subrole can
    #      produce (offers.yml keyword map, plus the `shop` categories of a
    #      stocked venue they staff);
    #   2. the table — at most TABLE_CAP unsold offers per seller per place;
    #   3. the day — at most PHASE_CAP materialisations per character per
    #      clock phase, stock's stand-in until stock exists.
    # The library mints the stats; the character's own label names the row.
    module Offers
      MAP_PATH  = Rails.root.join("lib/harness/items/inventory/offers.yml")
      # People who keep no table whatever the town lives on. Everyone else with
      # a trade word the map does not know sells what the settlement produces.
      NO_TABLE = %w[labourer laborer commoner guard soldier miner child boy girl beggar priest monk nun minstrel bard
                    hermit pilgrim wanderer traveler traveller bandit mercenary elder widow servant scribe healer].freeze
      BASIS_CATEGORIES = {
        "herding" => %w[goods provisions], "wool" => %w[goods], "fish" => %w[provisions goods], "farm" => %w[provisions],
        "grain" => %w[provisions], "orchard" => %w[provisions], "vine" => %w[provisions], "brew" => %w[provisions],
        "logging" => %w[goods], "timber" => %w[goods], "forest" => %w[goods], "peat" => %w[goods], "charcoal" => %w[goods],
        "mining" => %w[goods], "ore" => %w[goods], "iron" => %w[goods], "quarr" => %w[goods], "stone" => %w[goods],
        "salt" => %w[goods], "craft" => %w[goods],
        "trade" => %w[goods provisions], "market" => %w[goods provisions], "port" => %w[goods provisions], "harbo" => %w[goods provisions]
      }.freeze
      ANY_BASIS = %w[goods provisions].freeze
      TABLE_CAP = 3   # unsold things one seller may have out at a place
      PHASE_CAP = 4   # materialisations per character per clock phase
      LABEL_MAX = 40

      module_function

      # Categories this character could bring out; [] for most people.
      def categories_for(npc, location)
        return [] unless npc
        load!
        key  = npc.subrole.to_s.downcase.tr("_", " ")
        cats = @map.select { |kw, _| key.include?(kw) }.values.flatten
        if cats.empty? && key.strip != "" && NO_TABLE.none? { |w| key.include?(w) }
          # An unmapped trade (a salter, a charcoal burner) sells what the
          # settlement produces — a generated world names more trades than
          # any list (items run 7: Bess the salt worker, no table, salt in prose).
          basis = ::Harness::Settlement::Facts.for(location)["economic_basis"].to_s
          cats  = BASIS_CATEGORIES.find { |k, _| basis.include?(k) }&.last || (basis.empty? ? [] : ANY_BASIS)
        end
        props = location&.properties
        cats += Array(props["shop"]) if props.is_a?(Hash) && npc.home_location_id == location.id
        cats.uniq & ::Harness::Items::Library::CATEGORIES
      end

      # Unsold things this seller already has on the table here.
      def on_table(npc, location)
        return 0 unless npc && location
        ::Item.where(location_id: location.id).count do |i|
          i.properties.is_a?(Hash) && i.properties["for_sale"] && i.properties["seller_id"] == npc.id
        end
      end

      def phase_key(game_time)
        "#{game_time.to_i / ::Harness::Clock::MINUTES_PER_DAY}-#{::Harness::Clock.phase(game_time)}"
      end

      def brought_out(npc, game_time)
        props = npc.properties.is_a?(Hash) ? npc.properties : {}
        props.dig("brought_out", phase_key(game_time)).to_i
      end

      def budget_left?(npc, game_time)
        brought_out(npc, game_time) < PHASE_CAP
      end

      # The character's word for the thing, fit to be a row name; nil when it
      # isn't one.
      def clean_label(label)
        l = label.to_s.strip.gsub(/\s+/, " ").delete('"').sub(/\A(an?|the|some|this|that|my)\s+/i, "")
        l.empty? || l.length > LABEL_MAX ? nil : l
      end

      # Mint on the character's word. `at:` puts it on the table for sale;
      # `to:` puts it straight into a recipient's hands. Returns the Item, or
      # nil when the category has no templates.
      def materialize!(npc, category:, label:, game_time:, at: nil, to: nil, rng: Random.new)
        raise ArgumentError, "exactly one of at: or to:" if at.nil? == to.nil?
        template = ::Harness::Items::Library.template_for(category, label: label, rng: rng)
        return nil unless template
        item  = ::Harness::Items::Generator.instantiate(template, owner: to, location: at, rng: rng)
        props = item.properties.is_a?(Hash) ? item.properties.dup : {}
        if at
          props["for_sale"]  = true
          props["seller_id"] = npc.id
        end
        item.update!(name: clean_label(label) || item.name, properties: props)
        stamp!(npc, game_time)
        item
      end

      # A painted figure's object, made real with the figure. The eyes paint
      # "an old man balancing a wheel of cheese on his knee"; the player asks
      # the price; the voice quotes cheese that has no row (items run 6, t1).
      # At promotion the description is read against the library and the
      # first matching kind goes on the new person's table, under their name,
      # at the engine's price. One thing, budget-stamped; nil when nothing in
      # the description is a thing the library knows.
      def materialize_described!(npc, desc, location, game_time)
        return nil unless npc && location && desc.to_s.strip != ""
        template = %w[provisions goods weapons armor jewelry].lazy
                   .map { |c| ::Harness::Items::Library.template_matching(c, desc) }.find(&:itself)
        return nil unless template
        item  = ::Harness::Items::Generator.instantiate(template, location: location)
        props = item.properties.is_a?(Hash) ? item.properties.dup : {}
        props["for_sale"]  = true
        props["seller_id"] = npc.id
        kind = ::Harness::Items::Library.kind_matching(template, desc)   # the thing as painted, not a random kin of it
        item.update!(name: kind || item.name, properties: props)
        stamp!(npc, game_time)
        item
      end

      # Count this materialisation against the character's phase budget. Only
      # the current phase is kept — the row never accumulates history.
      def stamp!(npc, game_time)
        props = (npc.properties.is_a?(Hash) ? npc.properties : {}).dup
        key   = phase_key(game_time)
        props["brought_out"] = { key => props.dig("brought_out", key).to_i + 1 }
        npc.update!(properties: props)
      end

      # Test seam — drops the cached map.
      def reload!
        @map = nil
      end

      def load!
        return if @map
        raw  = YAML.safe_load_file(MAP_PATH, permitted_classes: [], aliases: false) || {}
        @map = raw.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = Array(v).map(&:to_s) }
      end
    end
  end
end
