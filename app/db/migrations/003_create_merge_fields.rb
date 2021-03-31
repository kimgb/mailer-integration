Sequel.migration do
  up do
    create_table(:merge_fields) do
      primary_key :id
      foreign_key :list_id, :lists
      String :mailchimp_id, null: false, unique: true, index: true
      String :type, null: false, unique: false, index: true
      String :name, null: false, unique: true, index: false
      String :tag, null: false, unique: true, index: false
    end
  end
  
  down do
    drop_table(:merge_fields)
  end
end
