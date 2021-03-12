class List < Sequel::Model(APPDB[:lists])
  one_to_many :categories
end
