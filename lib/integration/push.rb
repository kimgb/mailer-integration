require 'digest'

class Mailer::Integration::Push < Mailer::Integration
  attr_reader :config, :contacts, :columns

  # Mailer::Integration::Push.new()
  def initialize(path)
    if path.directory?
      @base_dir = path
    else
      raise ArgumentError, "#{path} is not a directory"
    end

    @thread_count = ::APP_CONFIG[:thread_count]
    @config = Configuration.new(YAML.load(File.read(base_dir + (base_dir.basename.to_s + ".yml"))))
    @columns = DB[config.table].columns
  end

  def run!
    @this_runtime = Time.new.utc
    logger.info "Run commencement at #{@this_runtime} (all times in UTC)"
    logger.info "Syncing interests"

    sync_interests()

    logger.info "Done syncing interests"
    logger.info "Fetching contacts to be synced from database"

    @contacts = DB[config.table].where(config.constraints(read_runtime)).all
    create_fields(config.merge_fields(columns)) unless @contacts.empty?
    # create_fields(config.merge_fields(@contacts[0])) if @contacts.size > 0

    logger.info "Found #{contacts.size} contacts to be synced"
    logger.info "BEGINNING SYNC TO MAILER"

    threads = []
    begin
      # Four threads runs at concurrency limit most of the time, but leave gaps (this is desirable, I think). I've used mutex in the past here, but now the only shared resource is a Logger, which rolls its own mutex.
      send_contacts(0)
      #(0..(@thread_count - 1)).map { |i| threads << sync_thread(i) }
      #threads.map(&:join)

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
  # TODO For ease of operation in development etc, needs to pick up on
  # categories and interests that have already been pushed to Mailchimp.
  def sync_interests
    # Get our Interest columns, and discard the signifier.
    interest_categories = columns.map(&:to_s)
      .select { |col| col.gsub!(/^interest/, "") }
      .map { |col| col.split("$") }
      .group_by(&:first) # Group by category title
      .map { |k,v| [k, v.map(&:last)] } # Remove category title from groups
      .to_h # so that the category and interests get parsed as two args below

    interest_categories.each(&method(:sync_category_and_interests)) #{ |k, v| sync_category_and_interests(k, v) }
  end

  def sync_category_and_interests(category_title, interest_names)
    category = Category.find(list_id: config.list_id, title: category_title) ||
      create_interest_category(category_title)

    interests = interest_names.map do |name|
      Interest.find(name: name) || create_interest(category, name)
    end

    [category, interests]
  end

  # Creates an interest category for a Mailchimp list, given a list ID and a
  # title.
  def create_interest_category(title)
    logger.info "Creating interest category '#{title}'"
    response = ::API.lists(config.list_id).interest_categories.create(body: { title: title, type: "hidden" })

    Category.create(mailchimp_id: response.body["id"], title: title, list_id: config.list_id)
  end

  # Creates an interest for a Mailchimp list, given a list ID, a category ID
  # and a name.
  # TODO handle alteration and deletion through the Mailchimp web GUI. Perhaps
  # attempt a GET on the interest path.
  def create_interest(category, name)
    logger.info "Creating interest '#{name}' in category '#{category.title}'"
    response = ::API.lists(config.list_id).interest_categories(category.mailchimp_id).interests.create(body: { name: name })

    Interest.create(mailchimp_id: response.body["id"], name: name, category: category)
  end

  # Spawns a subscriber sync thread.
  def sync_thread(i)
    logger.debug "Spooling up sync thread #{i}"

    Thread.new do
      send_contacts(i)
    end
  end

  def create_fields(fields)
    http = http_root

    existing_fields =  http.lists(config.list_id).merge_fields
      .retrieve(params: { fields: "merge_fields.name", count: 1000 })
      .body[:merge_fields]
      .map{|i| i[:name]}
      .uniq

    new_fields = fields - existing_fields

    new_fields.each do |f|
      http.lists(config.list_id).merge_fields.create(body: {name: f.to_s, type: "text", tag: f.to_s})
    end

  end

  def delete_all_fields
    existing_fields =  http_root.lists(config.list_id).merge_fields.retrieve(params: { fields: 'merge_fields.merge_id' }).body[:merge_fields].map{|i| i[:merge_id]}
    existing_fields.each { |i| http_root.lists(config.list_id).merge_fields(i).delete }
  end

  def send_contacts(i)
    http = http_root(i)

    operations = []
    (i..@contacts.size - 1).step(@thread_count) do |n|
      body = parameterise(@contacts[n])
      operations << {
        method: "PUT",
        path: "lists/#{config.list_id}/members/#{Digest::MD5.hexdigest body['email_address']}",
        #path: "lists/#{config.list_id}/members",
        body: body.to_json
      }
    end

    #puts operations

    batch = http.batches.create({
      body: {
        operations: operations
      }
    })

    logger.info "Batch starting #{Time.now}"

    batch = wait_for(http, batch.body[:id])

    total = batch.body[:total_operations]
    errors = batch.body[:errored_operations]
    response_body_url = batch.body[:response_body_url]

    logger.info "Batch finished #{Time.now}, #{errors} errors of #{total} members.  response_body_url: #{response_body_url}"

    batch
  end

  def wait_for(http, batch_id)
    batch = nil
    loop do
      sleep 3
      batch =  http.batches(batch_id).retrieve
      break if "finished" == batch.body[:status]
    end

    batch
  end

  def parameterise(contact)
    result = {
      "status" => contact[:subscription_status],
      "email_address" => contact[:email],
      "merge_fields" => merge_fields(contact),
      "interests" => interest_fields(contact)
    }
    result
    #payload.merge!(config.friendly_field_map(contact)) unless config.field_map.nil?
    #post.set_form_data(payload)
    #post
  end

  def merge_fields(contact)
    result = {}
    contact.slice(*config.merge_fields(contact.stringify_keys).map(&:to_sym)).each do |k,v|
      result[k.upcase] = v unless v.nil?
    end

    result
  end

  def interest_fields(contact)
    contact.stringify_keys.select { |col| col =~ /^interest/ }.map do |k,v|
      category, name = k.gsub(/^interest/, "").split("_")
      interest = Interest.find_by_list_category_and_name(config.list_id, category, name)

      [interest.mailchimp_id, v==1 ? true : false]
    end.to_h
  end
end
