# Active Support's Hash extensions give us Hash#except and HashWithIndifferentAccess
require 'active_support/core_ext/hash'
# String inflections give us classify, constantize etc.
require 'active_support/core_ext/string/inflections'

# Core Ruby dependencies
require 'yaml'
require 'pathname'
require 'net/http'
require 'net/https'
require 'json'
require 'optparse'
require 'sequel'

# Load in our config files
APP_CONFIG ||= YAML.load(File.read(app_root + "config" + "config.yml")).freeze
PULL_CONFIG ||= YAML.load(File.read(app_root + "config" + "pull.yml")).freeze
DB ||= Sequel.connect(APP_CONFIG[:db_connect]) # TODO can replace db_adapter.rb?

# Lastly, our lib files - sometimes relying on the constants defined above
require_relative 'integration_base'
require_relative 'integration/push'
require_relative 'integration/configuration'
require_relative 'integration/pull'
