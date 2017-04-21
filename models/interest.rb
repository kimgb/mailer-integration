class Interest < Sequel::Model(APPDB[:interests])
  many_to_one :category

  def self.find_by_list_category_and_name(list_id, category_title, name)
    category = Category.find(list_id: list_id, title: category_title)

    find(category: category, name: name)
  end
end
