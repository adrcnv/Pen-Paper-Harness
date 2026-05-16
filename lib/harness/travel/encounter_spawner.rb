module Harness
  module Travel
    # Creates a wilderness_leaf Location at exact cursor coords (no rejection
    # sampling — the encounter happened HERE), tags it with
    # properties.kind="wilderness_leaf" + properties.encounter_type=<bucket>,
    # logs an introduction event, and runs Genesis (small-model backstory pass).
    #
    # Distinct from Tools::ProposeLocation's wilderness_leaf path because:
    #   - propose_location is user-driven and rejection-samples coords
    #   - encounter spawn is system-driven at known coords
    #   - they share the row-shape and downstream consumers (Genesis,
    #     auto-Materializer at scene entry)
    #
    # Genesis is intentionally NOT run for encounter leaves. They're
    # ephemeral by design — the player passes through, plays the scene out,
    # may never return. Spending tokens to back-generate 0-5 past events for
    # a transient bandit-encountered cottage is wasted cost. Worldgen
    # cities still get genesis-on-entry via Scene::Manager; that's where
    # genesis pays for itself.
    module EncounterSpawner
      def self.spawn(name:, description:, x:, y:, encounter_type:, context:)
        anchor = nearest_top_level(x, y)
        biome  = anchor&.biome || ::Harness::Worldgen::Biome::LOWLAND

        loc = ::ActiveRecord::Base.transaction do
          ::Location.create!(
            name:        name,
            description: description,
            x:           x,
            y:           y,
            biome:       biome,
            properties:  {
              "kind"           => "wilderness_leaf",
              "encounter_type" => encounter_type
            }
          )
        end

        intro_event = ::Harness::Event::ForwardAppender.append(
          game_time: context.game_time,
          scope:     "local",
          location:  loc,
          details: {
            "introduction" => {
              "target_type"    => "location",
              "target_id"      => loc.id,
              "target_name"    => loc.name,
              "kind"           => "wilderness_leaf",
              "encounter_type" => encounter_type,
              "connection"     => "encountered mid-journey",
              "anchor"         => anchor&.name
            }
          },
          participants: []
        )

        {
          location:    loc,
          intro_event: intro_event
        }
      end

      def self.nearest_top_level(x, y)
        ::Location.where(parent_id: nil).where.not(x: nil, y: nil).to_a.min_by { |l|
          Math.hypot(l.x - x, l.y - y)
        }
      end
    end
  end
end
