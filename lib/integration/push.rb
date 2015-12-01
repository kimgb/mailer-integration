class Mailer::Integration::Push < Mailer::Integration
  attr_reader :config, :contacts

  # Mailer::Integration::Push.new()
  def initialize(path)
    if path.directory?
      @base_dir = path
    else
      raise ArgumentError, "#{path} is not a directory"
    end

    @config = Configuration.new(YAML.load(File.read(base_dir + (base_dir.basename.to_s + ".yml"))))
  end

  def run!
    @this_runtime = Time.new.utc
    logger.info "Run commencement at #{@this_runtime} (all times in UTC)"
    logger.info "Fetching contacts to be synced from database"

    @contacts = DB[config.table].where(config.constraints(read_runtime)).all

    logger.info "Found #{contacts.size} contacts to be synced"
    logger.info "*** BEGINNING SYNC TO MAILER ***"

    threads = []
    begin
      # Four threads runs at concurrency limit most of the time, but leave gaps (this is desirable, I think). I've used mutex in the past here, but now the only shared resource is a Logger, which rolls its own mutex.
      (0..3).map { |i| threads << sync_thread(i) }
      threads.map(&:join)

      logger.info "Finished, saving this run as complete"
      save_runtime(@this_runtime)
    # Keep an eye out for more specific errors
    rescue Exception => err
      logger.error "ERROR #{err.class}: #{err.message}"
      logger.error err.backtrace
    ensure
      logger.close
    end
  end

  private
  # Spawns a subscriber sync thread.
  def sync_thread(i)
    logger.debug "Spooling up sync thread #{i}"

    Thread.new do
      (i..@contacts.size - 1).step(4) do |n|
        http = http_root(i)
        contact = @contacts[n]
        update_contact(http, contact)
      end
    end
  end

  def update_contact(http, contact)
    reqres = http.request(parameterise(contact))
    response = JSON.parse(reqres.body)

    logger.debug "Attempted to update contact with email #{contact[:email]}, response #{response["result_code"] == 1 ? '1 OK' : '0 Failed'}: #{response["result_message"]}"

    response
  end

  # Be aware - ActiveCampaign fields that are custom (that's most of them!)
  # need to be created before use, either through the API or in the UI.
  def parameterise(contact)
    post = sync_subscriber

    payload = {
      "p[#{config.list_id}]" => config.list_id,
      # TODO instantresponder
      "email" => contact[:email],
      "first_name" => contact[:firstname],
      "last_name" => contact[:lastname]
    }
    payload.merge!(config.friendly_field_map(contact)) unless config.field_map.nil?
    post.set_form_data(payload)

    post
  end

  ## Instantiate request object to the Mailer API.
  def sync_subscriber
    query_params = queryise(api_key: ::APP_CONFIG[:api_key], api_action: "subscriber_sync",
      api_output: "json")
    Net::HTTP::Post.new("/admin/api.php?#{query_params}")
  end
end
