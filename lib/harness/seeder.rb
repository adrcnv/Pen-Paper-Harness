module Harness
  class Seeder
    def self.build(&block)
      new.tap { |b| b.instance_eval(&block) if block }
    end

    def seed_frame(frame)
      frame = frame.deep_stringify_keys

      factions = {}
      Array(frame["kingdoms"]).each do |k|
        name = k.fetch("name")
        subrole = k["subrole"] || "kingdom"
        extras = k.reject { |key, _| %w[name subrole].include?(key) }.transform_keys(&:to_sym)
        factions[name] = faction(name, subrole: subrole, is_kingdom: true, **extras)
      end

      locations = {}
      Array(frame["cities"]).each do |c|
        name         = c.fetch("name")
        description  = c["description"]
        kingdom_name = c["kingdom"]
        kingdom = if kingdom_name
          factions[kingdom_name] || ::Faction.find_by(name: kingdom_name)
        end
        extras = c.reject { |key, _| %w[name description kingdom].include?(key) }.transform_keys(&:to_sym)
        locations[name] = location(name, description: description, faction: kingdom, **extras)
      end

      # The Path model was retired in favor of cursor-based travel
      # (any coords → any coords). Frame skeletons may still emit a "paths"
      # array — we ignore it.
      { factions: factions, locations: locations }
    end

    def seed_sublocations(city:, entries:)
      Array(entries).map do |raw|
        e = raw.deep_stringify_keys
        location(
          e.fetch("name"),
          description: e["description"],
          parent: city,
          kind: e["kind"]
        )
      end
    end

    def seed_factions(city:, entries:)
      Array(entries).map do |raw|
        e = raw.deep_stringify_keys
        f = faction(
          e.fetch("name"),
          subrole: e.fetch("subrole"),
          disposition: e["disposition"]
        )
        Array(e["claimed_sublocations"]).each do |subloc_name|
          sub = city.children.find_by!(name: subloc_name)
          sub.update!(faction: f)
        end
        f
      end
    end

    def location(name, description: nil, parent: nil, faction: nil, **extras)
      column_keys = ::Location.column_names.map(&:to_sym)
      column_attrs, prop_attrs = extras.partition { |k, _| column_keys.include?(k) }.map(&:to_h)
      attrs = { name: name, description: description, parent: parent, faction: faction }.merge(column_attrs)
      attrs[:properties] = prop_attrs.stringify_keys if prop_attrs.any?
      ::Location.create!(attrs)
    end

    def npc(name, subrole:, location: nil, **attrs)
      stats, extras = split_stats(attrs)
      ::Npc.create!({
        name: name,
        subrole: subrole,
        location: location,
        properties: extras.stringify_keys
      }.merge(stats))
    end

    def player(name, subrole: nil, location: nil, **attrs)
      stats, extras = split_stats(attrs)
      ::Player.create!({
        name: name,
        subrole: subrole,
        location: location,
        properties: extras.stringify_keys
      }.merge(stats))
    end

    # Legacy alias. Prefer #npc (or #player) in new code.
    def character(name, **kwargs)
      npc(name, **kwargs)
    end

    def split_stats(attrs)
      stat_keys = ::Character::STATS.map(&:to_sym)
      stats  = attrs.slice(*stat_keys)
      extras = attrs.except(*stat_keys)
      [ stats, extras ]
    end

    def faction(name, subrole:, is_kingdom: false, **properties)
      ::Faction.create!(
        name: name,
        subrole: subrole,
        is_kingdom: is_kingdom,
        properties: properties.stringify_keys
      )
    end

    def item(name, subrole:, location: nil, character: nil, **properties)
      ::Item.create!(
        name: name,
        subrole: subrole,
        location: location,
        character: character,
        properties: properties.stringify_keys
      )
    end

    def event(game_time:, scope: "personal", location: nil, participants: {}, **details)
      ::Event.create!(
        game_time: game_time,
        scope:     scope,
        location:  location,
        details:   details
      ).tap do |ev|
        participants.each do |who, role|
          unless who.is_a?(::Character)
            raise ArgumentError, "post-Phase-2 seeder requires Character participants (got #{who.inspect}); class-2 actor_name strings retired"
          end
          ::EventParticipant.create!(event: ev, character: who, role: role.to_s)
        end
      end
    end
  end
end
