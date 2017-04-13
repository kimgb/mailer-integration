class Mailer::Integration::Push::Configuration
  attr_reader :list_id, :table, :field_exclusions, :since

  def initialize(yaml)
    @list_id = yaml[:list_id]
    @table = yaml[:table]
    @field_exclusions = yaml[:field_exclusions]
    @since = yaml[:since]
  end

  def constraints(last_run)
    since.map { |col| "#{col} > '#{last_run}'" }.join(" OR ")
  end

  def merge_fields(contact)
    contact.stringify_keys.except(*(since+field_exclusions+['email', 'subscription_status'])).keys
  end
end
