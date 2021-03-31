class MergeField < Sequel::Model(APPDB[:merge_fields])
  many_to_one :list
end
