# Active Support's Hash extensions give us Hash#except and HashWithIndifferentAccess
require 'active_support/core_ext/hash'
# String inflections give us classify, constantize etc.
require 'active_support/core_ext/string/inflections'

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
APP_ROOT = Pathname(__FILE__).dirname.parent

# Load in our config files, and initialise constants
APP_CONFIG ||= YAML.load(File.read(APP_ROOT + "config" + "config.yml")).freeze
PULL_CONFIG ||= YAML.load(File.read(APP_ROOT + "config" + "pull.yml")).freeze

# Database and API objects
DB ||= Sequel.connect(APP_CONFIG[:db_connect])
# `sequel -m db/migrations/ sqlite://app.db`
APPDB ||= Sequel.sqlite((APP_ROOT + "db" + "app.db").to_s)

# Set up constants for the Mailchimp standard and Export APIs.
API = Gibbon::Request.new(api_key: APP_CONFIG[:api_key])
EXPORT_API = Gibbon::Export.new(api_key: APP_CONFIG[:api_key])

# Schema transformations
CAMPAIGN = PULL_CONFIG[:campaign].freeze
SUBSCRIBER = PULL_CONFIG[:subscriber].freeze
JUNCTION = PULL_CONFIG[:junction].freeze

# Lastly, our lib files - as they sometimes rely on the constants defined above
require_relative '../models/category'
require_relative '../models/interest'
require_relative 'integration_base'
require_relative 'integration/push'
require_relative 'integration/configuration'
require_relative 'integration/pull'
