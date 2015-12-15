# Active Support's Hash extensions give us Hash#except and HashWithIndifferentAccess
require 'active_support/core_ext/hash'
# String inflections give us classify, constantize etc.
require 'active_support/core_ext/string/inflections'

# Core Ruby dependencies
require 'yaml'
require 'pathname'
require 'logger'
require 'net/http'
require 'net/https'
require 'json'
require 'optparse'
require 'sequel'
require 'pry'
require 'slack-notifier'

# Set app root directory
APP_ROOT = Pathname(__FILE__).dirname.parent

# Load in our config files, and initialise constants
APP_CONFIG ||= YAML.load(File.read(APP_ROOT + "config" + "config.yml")).freeze
PULL_CONFIG ||= YAML.load(File.read(APP_ROOT + "config" + "pull.yml")).freeze

DB ||= Sequel.connect(APP_CONFIG[:db_connect])
CAMPAIGN = PULL_CONFIG[:campaign].freeze
SUBSCRIBER = PULL_CONFIG[:subscriber].freeze
JUNCTION = PULL_CONFIG[:junction].freeze

# Lastly, our lib files - as they sometimes rely on the constants defined above
require_relative 'integration_base'
require_relative 'integration/push'
require_relative 'integration/configuration'
require_relative 'integration/pull'
