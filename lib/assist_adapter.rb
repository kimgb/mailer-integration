# assist_adapter.rb
# Sequel and config.rb should be required already at this stage, but included
# for debugging purposes.

require 'sequel'
require '../config/config'

module AssistAdapter
  def client # more explicitly - assist_client?
    return @client if @client

    @client = Sequel.connect(ASSIST_CONFIG)
    ["ANSI_WARNINGS", "ANSI_NULLS", "ANSI_PADDING", "CONCAT_NULL_YIELDS_NULL"]
      .each { |c| @client.run("SET #{c} ON") }

    @client
  end

  alias_method :assist_client, :client

  def contacts_with_email
    assist_client[contacts_with_email_sql]
  end

  def vic_dels_marguerite
    assist_client[vic_dels_marguerite_sql]
  end

  def staff
    assist_client[staff_sql]
  end
end
