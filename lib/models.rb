require 'sequel'

DB ||= Sequel.connect(APP_CONFIG[:assist_config])

class Rec < Sequel::Model(:rec)
  many_to_many :contacts, left_key: :recid, right_key: :contactid,
                          join_table: :contactrec
end

class Contact < Sequel::Model(:contact)
  many_to_many :recs,     left_key: :contactid, right_key: :recid,
                          join_table: :contactrec
end

class ContactRec < Sequel::Model(:contactrec)
  many_to_one :rec,     key: :recid
  many_to_one :contact, key: :contactid
end
