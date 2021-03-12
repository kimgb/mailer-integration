class Category < Sequel::Model(APPDB[:categories])
  many_to_one :list
  one_to_many :interests
end
