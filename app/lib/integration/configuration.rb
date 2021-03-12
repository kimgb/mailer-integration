class Mailer::Integration::Push::Configuration
  attr_reader :list_id, :name, :settings, :table, :purge_stale_emails, :field_exclusions, :since

  def initialize(yaml)
    # @list_id = yaml[:list_id]
    @name = yaml[:name]
    @settings = yaml[:audience_settings]
    @table = yaml[:table]
    @purge_stale_emails = yaml[:purge_stale_emails]
    @field_exclusions = yaml[:field_exclusions]
    @since = yaml[:since]
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
end
