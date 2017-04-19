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

    # def parse_request(request_object)
    #   JSON.parse(root.request(request_object).body)
    # end

    def read_runtime
      if File.exists?(run_file)
        DateTime.parse(File.open(run_file, &:readline).strip)
      else
        DateTime.parse('1970-01-01')
      end
    end

    def save_runtime(time)
      File.open(run_file, "w") { |f| f.puts time.utc.strftime("%FT%T") }
    end
  end
end
