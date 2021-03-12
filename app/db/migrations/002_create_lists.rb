Sequel.migration do
  up do
    create_table(:lists) do
      primary_key :id
      String :mailchimp_id, null: false, unique: true, index: true
      String :title, null: false, unique: true, index: true
    end
    
    alter_table(:categories) do
      rename_column :list_id, :mailchimp_list_id
      add_foreign_key :list_id, :lists
    end
  end
  
  down do
    alter_table(:categories) do
      drop_foreign_key :list_id
      rename_column :mailchimp_list_id, :list_id
    end
    
    drop_table(:lists)
  end
end
