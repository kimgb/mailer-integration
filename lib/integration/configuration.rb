class Mailer::Integration::Push::Configuration
  attr_reader :list_id, :table, :field_exclusions, :since

  def initialize(yaml)
    @list_id = yaml[:list_id]
    @table = yaml[:table]
    @field_exclusions = yaml[:field_exclusions]
    @since = yaml[:since]
  end

  def constraints(last_run)
    since.map { |col| "#{col} > '#{last_run.strftime("%F")}'" }.join(" OR ")
  end

  def merge_fields(columns) #(contact)
    all_exclusions = [*(since + field_exclusions + ['email', 'subscription_status'])]
    columns.map(&:to_s).reject { |col| col.start_with?("interest") } - all_exclusions

    # contact.stringify_keys.except(*(since+field_exclusions+['email', 'subscription_status'])).keys
  end
end
