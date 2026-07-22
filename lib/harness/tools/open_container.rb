module Harness
  module Tools
    # Open a chest / container at the actor's location. If it's locked, the actor
    # makes a DEXTERITY check against the lock's difficulty (the harder the lock,
    # the richer the hoard) — failure leaves it closed and the actor may try
    # again (time passes). On success the hoard is rolled FRESH (Treasure::
    # LootTable): items spill onto the floor as present_items (pick them up
    # normally), coins go straight to the opener. The chest is then empty/open.
    #
    # The core decides what's inside and the lock outcome; the LLM only chooses
    # to open it.
    class OpenContainer < Base
      PICK_MINUTES = 3   # time spent working a lock / prying a lid

      def self.tool_name
        "open_container"
      end

      def self.schema
        {
          "name"        => tool_name,
          "description" => "Open a chest or container present in the scene (an item with container=true in query_scene present_items). If locked, the opener makes a Dexterity check against the lock; on failure it stays shut and can be retried. On success its contents drop to the floor (appear in present_items, pick them up) and any coins go to the opener. by_character_id defaults to the player.",
          "input_schema" => {
            "type"       => "object",
            "properties" => {
              "item_id"         => { "type" => "integer", "description" => "the container to open (container=true in present_items)" },
              "by_character_id" => { "type" => "integer", "description" => "who opens it; defaults to the player" }
            },
            "required" => [ "item_id" ]
          }
        }
      end

      def call(args, context)
        item_id = args["item_id"]
        actor_id = args["by_character_id"] || ::Player.first&.id

        return { "error" => "item_id required" } if item_id.nil?
        return { "error" => "no opener (no by_character_id and no player row)" } if actor_id.nil?

        actor = ::Character.find_by(id: actor_id)
        return { "error" => "no character with id=#{actor_id}" } unless actor

        item = ::Item.find_by(id: item_id)
        return { "error" => "no item with id=#{item_id}" } unless item
        return { "error" => "item id=#{item_id} is not a container" } unless ::Harness::Treasure::Chest.container?(item)
        return { "error" => "the #{item.name} is already open" } if item.properties["state"] == "open"

        loc = item.location
        return { "error" => "container id=#{item_id} is not at a location" } unless loc
        return { "error" => "opener id=#{actor_id} is not where the #{item.name} is" } unless actor.location_id == loc.id

        locked = item.properties["locked"]
        if locked
          outcome = ::Harness::Dice.check(actor_stat: actor.stat("dexterity"), difficulty: locked.to_s)
          ::Harness::Clock.advance(context, minutes: PICK_MINUTES, reason: "open_container(pick #{item.name})")
          if outcome.result.to_s.include?("failure")
            log_attempt(actor, item, outcome, context)
            return {
              "opened"     => false,
              "item_id"    => item.id,
              "item_name"  => item.name,
              "locked"     => true,
              "difficulty" => locked,
              "outcome"    => outcome.result,
              "roll"       => outcome.roll,
              "against"    => outcome.against
            }
          end
        end

        # A picked lock pays check XP by its difficulty tier (player only).
        # One-shot by construction: success consumes the lock.
        xp_award = nil
        if locked && actor.is_a?(::Player)
          amount   = ::Harness::Character::XP.for_check(difficulty: locked.to_s)
          xp_award = ::Harness::Character::XP.award!(actor, amount) if amount.positive?
        end

        rarity = item.properties.dig("loot", "rarity") || "common"
        hoard  = ::Harness::Treasure::LootTable.spawn(rarity: rarity, location: loc, rng: Random.new)

        ::ActiveRecord::Base.transaction do
          actor.update!(coins: actor.coins + hoard[:coins]) if hoard[:coins].positive?
          props = item.properties.dup
          props["state"] = "open"
          props.delete("locked")
          props.delete("loot")
          item.update!(properties: props)
        end

        log_open(actor, item, hoard, context)

        {
          "opened"      => true,
          "item_id"     => item.id,
          "item_name"   => item.name,
          "items"       => hoard[:items].map { |i| { "id" => i.id, "name" => i.name } },
          "coins_found" => hoard[:coins],
          "opener_balance" => actor.coins,
          "xp_gained"   => xp_award&.dig(:gained),
          "leveled_up"  => xp_award && xp_award[:levels_gained] > 0 ? true : nil,
          "new_level"   => xp_award && xp_award[:levels_gained] > 0 ? xp_award[:new_level] : nil
        }.compact
      end

      private

      def log_attempt(actor, item, outcome, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0, scope: "personal", location: item.location,
          details: { "open_container" => { "item_id" => item.id, "item_name" => item.name, "result" => "failed_lock", "roll" => outcome.roll } },
          participants: [ { character: actor, role: "actor" } ]
        )
      end

      def log_open(actor, item, hoard, context)
        ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time || 0, scope: "personal", location: item.location,
          details: {
            "open_container" => {
              "item_id" => item.id, "item_name" => item.name, "result" => "opened",
              "items_found" => hoard[:items].map(&:name), "coins_found" => hoard[:coins]
            }
          },
          participants: [ { character: actor, role: "actor" } ]
        )
      end
    end
  end
end
