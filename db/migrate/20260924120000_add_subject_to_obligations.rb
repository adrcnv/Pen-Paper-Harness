class AddSubjectToObligations < ActiveRecord::Migration[8.0]
  def change
    # What a deed is owed IN, bound when the bargain is struck: {"is" =>
    # thing|person|work, "id" => an item or character row, "label" => the
    # thing or person as spoken, "kind" => an item category for a thing
    # the debtor does not carry yet}. Read at delivery, never by prose.
    add_column :obligations, :subject, :json, default: {}
  end
end
