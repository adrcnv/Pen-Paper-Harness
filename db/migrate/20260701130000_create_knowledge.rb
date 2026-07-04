class CreateKnowledge < ActiveRecord::Migration[8.1]
  # The KNOWLEDGE store — standing, faceted truth, distinct from the dated
  # EVENTS log. Distributed by FACET (you're a clerk / you're in Saltmere),
  # not by participation. A row's non-null facets are AND-gates; all-null =
  # world-general. Written once, read by every matching NPC (no per-NPC copy).
  #
  # `embedding` is nullable — semantic ranking lands later behind the
  # query_knowledge interface; facet-filtering works without it.
  def change
    create_table :knowledge do |t|
      t.text    :content, null: false          # the fact, as a statement
      # Facets (nullable gates; null = wildcard / world-general):
      t.string  :subrole                        # trade match against character.subrole (Harness::Vocations vocabulary)
      t.integer :location_id                    # place-ancestry anchor (matched up the tree)
      t.integer :min_int                        # education gate: known only at/above this INT
      t.string  :social_class                   # matched against character.social_class
      t.string  :faction                        # matched against character.faction
      # Non-facet:
      t.boolean :current, null: false, default: true   # supersession/staleness flag
      t.integer :source_id                      # provenance: the NPC/event that minted it
      t.string  :source_kind
      t.integer :game_time, null: false, default: 0
      t.text    :embedding                      # JSON float vector; filled when semantic lands
      t.timestamps
    end

    add_index :knowledge, :subrole
    add_index :knowledge, :location_id
    add_index :knowledge, :current

    # The character-side facet values these rows gate against. Deferred from
    # step 0 to here — this is the first code that reads them. Constant for
    # now (all commoners, factionless); informs appearance/gating later.
    add_column :characters, :social_class, :string, null: false, default: "commoner"
    add_column :characters, :faction,      :string, null: false, default: "factionless"
  end
end
