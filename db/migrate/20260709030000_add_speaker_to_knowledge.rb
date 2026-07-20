class AddSpeakerToKnowledge < ActiveRecord::Migration[8.0]
  def change
    # Provenance (audit seam #1, laundering lever b): who uttered the claim
    # this row was captured from. Capture always had it in hand and discarded
    # it. Foundation for the adverse-party merge policy; immediately useful
    # for forensics (which mouth did this "fact" come out of).
    add_column :knowledge, :speaker, :string
  end
end
