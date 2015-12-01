class Mailer::Integration::Push::Configuration
  attr_reader :list_id, :table, :field_map, :since

  def initialize(yaml)
    @list_id = yaml[:list_id]
    @table = yaml[:table]
    @field_map = yaml[:field_map]
    @since = yaml[:since]
  end

  def constraints(last_run)
    since.map { |col| "#{col} > '#{last_run}'" }.join(" OR ")
  end

  def friendly_field_map(contact)
    field_map.map { |k, v| ["field[#{v},0]", contact[k]] }.to_h
  end
end
