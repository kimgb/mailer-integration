module Mailer
  class Integration
    attr_reader :base_dir

    def run!
    end

    def base_dir=(path)
      if path.directory?
        @base_dir = path
      else
        raise ArgumentError, "#{path} is not a directory"
      end
    end

    def logger
      @logger ||= ::Logger.new(log_dir + "sync.log", "monthly")
    end

    def run_file
      log_dir + "last_run.txt"
    end

    def log_dir
      return @log_dir if @log_dir

      @log_dir = base_dir + "log"
      @log_dir.mkpath unless @log_dir.exist? && @log_dir.directory?

      @log_dir
    end

    def http_root(i = nil)
      if i
        instance_variable_get("@root#{i}") || set_http_root("@root#{i}")
      else
        @root || set_http_root("@root")
      end
    end

    def set_http_root(root_name)
      http = instance_variable_set(root_name, ::Net::HTTP.new(::APP_CONFIG[:mailer_uri], ::APP_CONFIG[:mailer_port]))
      http.use_ssl = true
      http.verify_mode = ::OpenSSL::SSL::VERIFY_NONE

      http
    end

    # def parse_request(request_object)
    #   JSON.parse(root.request(request_object).body)
    # end

    def read_runtime
      if File.exists?(run_file)
        Time.parse(File.open(run_file, &:readline).strip).utc.strftime("%FT%T")
      else
        Time.parse('1970-01-01').utc.strftime("%FT%T")
      end
    end

    def save_runtime(time)
      File.open(run_file, "w") { |f| f.puts time.utc.strftime("%FT%T") }
    end

    def queryise(hash)
      rollup_and_flatten_hash(hash).each_slice(2).map{ |a| URI.encode(a.join("=")) }.join("&")
    end

    # flattens a hash into an array while rolling up nested keys (recursive)
    # { filters: { since: "2015-06-21" } } => ["filters[since]", "2015-06-21"]
    def rollup_and_flatten_hash(hash, key="")
      hash.flat_map do |k, v|
        new_key = key + (key.empty? ? "#{k}" : "[#{k}]")
        v.is_a?(Hash) ? rollup_and_flatten_hash(v, new_key) : [new_key, v]
      end
    end
  end
end
