class Category < Sequel::Model(APPDB[:categories])
  one_to_many :interests
end
