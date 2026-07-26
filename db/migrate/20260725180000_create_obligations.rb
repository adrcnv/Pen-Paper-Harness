class CreateObligations < ActiveRecord::Migration[8.0]
  def change
    create_table :obligations do |t|
      t.integer :debtor_id,   null: false  # character who owes
      t.integer :creditor_id, null: false  # character owed
      t.string  :kind,        null: false  # coins | meet | deed
      t.integer :amount                    # coins kind; nil = unfixed ("a third of the take")
      t.text    :terms,       null: false  # the deal as agreed, one sentence
      t.string  :due                       # condition/time wording as spoken; nil = none stated
      t.string  :status,      null: false, default: "open"  # open | settled | broken | forgiven
      t.integer :game_time,   null: false, default: 0       # when struck
      t.integer :location_id                                # where struck
      t.timestamps
    end
    add_index :obligations, [ :debtor_id, :status ]
    add_index :obligations, [ :creditor_id, :status ]
  end
end
