# Active Support's Hash extensions give us Hash#except and HashWithIndifferentAccess
require 'active_support/core_ext/hash'
# String inflections give us classify, constantize etc.
require 'active_support/core_ext/string/inflections'

# Init inflections that we're likely to encounter.
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym 'ID'
  inflect.acronym 'IDs'
  inflect.acronym 'HSR'
  inflect.acronym 'HSRs'
end

# Installed Gems
require 'sequel'
require 'pry'
require 'gibbon'

# Core Ruby dependencies
require 'yaml'
require 'pathname'
require 'logger'
require 'net/http'
require 'net/https'
require 'json'
require 'optparse'

# Set app root directory
APP_ROOT ||= Pathname(__FILE__).dirname.parent

# Load in our config files, and initialise constants
APP_CONFIG ||= YAML.load(File.read(APP_ROOT + "config" + "config.yml")).freeze

if File.exist?(APP_ROOT + "config" + "pull.yml")
  PULL_CONFIG ||= YAML.load(File.read(APP_ROOT + "config" + "pull.yml")).freeze
  
  # Schema transformations
  CAMPAIGN = PULL_CONFIG[:campaign].freeze
  SUBSCRIBER = PULL_CONFIG[:subscriber].freeze
  JUNCTION = PULL_CONFIG[:junction].freeze
end

# Database and API objects
DB ||= Sequel.connect(adapter: "tinytds", username: ENV['SQL_SERVER_USER'], password: ENV['SQL_SERVER_PASS'], host: ENV['SQL_SERVER_HOST'], database: ENV['SQL_SERVER_DB'], appname: "mailchimp_integration", timeout: 60)
# `sequel -m db/migrations/ sqlite://app.db`
APPDB ||= Sequel.sqlite((APP_ROOT + "db" + "app.db").to_s)

# Set up constants for the Mailchimp standard and Export APIs.
API = Gibbon::Request.new(api_key: ENV['MAILCHIMP_API_KEY'])
EXPORT_API = Gibbon::Export.new(api_key: ENV['MAILCHIMP_API_KEY'])

# Lastly, our lib files - as they sometimes rely on the constants defined above
require_relative '../models/list'
require_relative '../models/category'
require_relative '../models/interest'
require_relative 'integration_base'
require_relative 'integration/push'
require_relative 'integration/configuration'
require_relative 'integration/pull'
