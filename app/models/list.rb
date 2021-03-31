class List < Sequel::Model(APPDB[:lists])
  one_to_many :categories
  one_to_many :merge_fields
end
