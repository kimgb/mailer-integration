Sequel.migration do
  up do
    create_table(:categories) do
      primary_key :id
      String :mailchimp_id, null: false, unique: true, index: true
      String :title, null: false, index: true
      String :list_id, null: false

      unique [:list_id, :title]
    end

    create_table(:interests) do
      primary_key :id
      foreign_key :category_id, :categories
      String :mailchimp_id, null: false, unique: true, index: true
      String :name, null: false, index: true

      unique [:category_id, :name]
    end
  end

  down do
    drop_table(:categories)
    drop_table(:interests)
  end
end
