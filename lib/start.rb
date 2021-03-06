require_relative 'loader'

log_level = 1
no_down = false
no_up = false

OptionParser.new do |opts|
  opts.banner = "Usage: ruby start.rb [options]"

  opts.on("-l", "--log-level=LEVEL", OptionParser::DecimalInteger,
          "Set the log level. 0/debug - 4/fatal.", "  Default is 1/info.") do |i|
    raise OptionParser::InvalidArgument unless (0..4).include? i
    log_level = i
  end

  opts.on("--no-down", "Don't run the sync from Active Campaign.") do
    no_down = true
  end

  opts.on("--no-up", "Don't run any of the 'up' integrations", "  to Active Campaign") do
    no_up = true
  end

  opts.on_tail("-h", "--help", "Show this message") { puts opts; exit }
end.parse!

# the pull integration bases itself out of APP_ROOT
unless no_down
  down_sync = Mailer::Integration::Pull.new(APP_ROOT)
  down_sync.run!
end

unless no_up
  # load all integration folders into an array
  integrations = Pathname.glob(APP_ROOT + "integrations" + "*")
  integrations.each do |integration|
    # ignore disabled integrations
    next if integration.basename.to_s.start_with?("_")
    begin
      up_sync = Mailer::Integration::Push.new(integration)
      up_sync.logger.level = log_level
      up_sync.run!
    rescue ArgumentError => e
      "Path was not a directory, skipping this integration"
    end
  end
end
