class Mailer::Integration::Push::Configuration
  attr_reader :name, :settings, :table, :purge_stale_emails, :field_exclusions, 
    :since, :merge_fields_map, :address_fields_map

  def initialize(yaml)
    @name = yaml[:name]
    @settings = yaml[:audience_settings]
    @table = yaml[:table]
    @purge_stale_emails = yaml[:purge_stale_emails]
    @field_exclusions = yaml[:field_exclusions] || []
    @since = yaml[:since] || []
    @merge_fields_map = yaml[:merge_fields_map] || {}
    @address_fields_map = yaml[:address_fields_map] || default_address_fields_map
  end

  def constraints(last_run = DateTime.new(1970, 1, 1))
    if since.present?
      Sequel.lit(since.map { |col| "#{col} > '#{last_run.strftime("%F")}'" }.join(" OR "))
    else Sequel.lit("1=1") end
  end

  def merge_fields(columns) #(contact)
    all_exclusions = [*(since + field_exclusions + ['email', 'subscription_status'])]
    columns.map(&:to_s).reject { |col| col.start_with?("interest") } - all_exclusions

    # contact.stringify_keys.except(*(since+field_exclusions+['email', 'subscription_status'])).keys
  end
  
  def address_columns
    @address_fields_map.keys
  end
  
  private
  # NOTE the values here are not up for debate; Mailchimp will only accept
  # addr1, addr2, city, state, country and zip as keys in the address object.
  # The keys should correspond to the relevant columns in your data source.
  def default_address_fields_map
    {
      addr1: :addr1,
      addr2: :addr2,
      city: :city,
      state: :state,
      country: :country,
      postcode: :zip
    }
  end
end
