module Harness
  module Scene
    # Snapshot of scene state at a moment — what the reasoning loop sees.
    # Transient; not persisted. Rebuild on scene transition, not mutated in place.
    Snapshot = Struct.new(
      :location, :present_characters, :present_corpses, :present_items,
      keyword_init: true
    )

    # Structural read of the presence CACHE — who is recorded at this
    # location. Scene::Whereabouts is the authority on where living NPCs are:
    # Manager#enter runs Whereabouts.refresh! before assembling, so by the
    # time this reads `location_id` the cache is fresh. Mid-scene re-assembly
    # (spawns, mutations) reads the same cache — presence doesn't shift under
    # a live scene. Do NOT add schedule logic here; that's the resolver's job.
    #
    # Rules:
    # - `present_characters` is literal to the cache. Earlier MVP pooled
    #   siblings (same parent); that broke down with spatially-distinct
    #   sublocations (the brewer is at her brewery, not at the bar).
    # - `present_items` stays literal to `location_id`. Items are anchored;
    #   they don't wander.
    # - Path-edge adjacency was retired with the Path model. Inter-location
    #   movement is now `transition` (sibling/parent/child) or `travel`
    #   (top-level coords → coords).
    class Assembler
      def self.for(location:)
        new(location).assemble
      end

      def initialize(location)
        @location = location
      end

      def assemble
        # A character is dead iff they were initialized (max_hp > 0) AND
        # have been zeroed (current_hp <= 0). Uninitialized rows
        # (max_hp == 0; never went through Hatchery — legacy/test fixtures)
        # count as alive: you can't die without first having been alive.
        # Dormant rows are excluded entirely — they exist structurally
        # (so event_participants can FK to them) but aren't in the scene
        # until something wakes them. See Scene::Materializer for the
        # wake path. Corpses stay: the cache stops being refreshed at death,
        # so the body lies where it fell.
        scoped = ::Npc.where(location_id: @location.id).reject { |c| dormant?(c) }
        living, dead = scoped.partition { |c|
          c.max_hp.to_i <= 0 || c.current_hp.to_i > 0
        }
        Snapshot.new(
          location:           @location,
          present_characters: living,
          present_corpses:    dead,
          present_items:      present_items
        )
      end

      private

      def dormant?(character)
        props = character.properties
        props.is_a?(Hash) && props["dormant"] == true
      end

      def present_items
        ::Item.where(location_id: @location.id).to_a
      end
    end
  end
end
