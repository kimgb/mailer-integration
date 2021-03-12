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

    # @thread_count = ::APP_CONFIG[:thread_count]
    @config = Configuration.new(YAML.load(File.read(base_dir + (base_dir.basename.to_s + ".yml"))))
    @columns = DB[config.table].columns
  end

  def run!
    @this_runtime = Time.new.utc
    logger.info "Run commencement at #{@this_runtime} (all times in UTC)"
    
    logger.info "Syncing list data"
    sync_list()
    logger.info "Done syncing list"
    
    logger.info "Syncing interests data"
    sync_interests()
    logger.info "Done syncing interests"

    logger.info "Fetching contacts to be synced from database"

    # @contacts = DB[config.table].where(config.constraints(read_runtime)).all
    # "table" is a misnomer here, this should really be a view in most cases.
    # email, firstname, lastname are the only mandatory fields IIRC.
    # any other column will either be pushed to a merge field (default)
    # or an interest category (if it has format interestCategory$Interest)
    @contacts = if config.since.present?
      DB[config.table].where(config.constraints(read_runtime)).all
    else
      DB[config.table].all
    end
    
    logger.info "Checking for new fields"
    fields = config.merge_fields(columns)
    fields_w_type = DB.schema(config.table).select { |f| fields.include?(f[0].to_s) }.to_h

    create_fields(fields_w_type) unless @contacts.empty?
    # create_fields(config.merge_fields(@contacts[0])) if @contacts.size > 0

    logger.info "Found #{contacts.size} contacts to be synced"
    logger.info "BEGINNING SYNC TO MAILER"

    begin
      send_contacts()

      logger.info "Finished, saving this run as complete"
      save_runtime(@this_runtime)
    # Keep an eye out for more specific errors
    rescue StandardError => err
      logger.error "ERROR #{err.class}: #{err.message}"
      logger.error err.backtrace
    ensure
      logger.close
    end
  end

  private
  def sync_list
    @list = List.find(name: config.name) || create_list(config.name)
  end
  
  def create_list(name)
    logger.info "Creating list '#{name}'"
    
    remote_lists = API.lists.retrieve.body["lists"]
    remote_list = remote_lists.find { |l| l["name"] == name }
    
    unless remote_list.present?
      # There are a lot of required properties when creating a list.
      # See the example integration config file.
      settings = config.settings.merge(name: name)
      response = API.lists.create(body: settings)
      
      remote_list = response.body
    end
    
    List.create(name: name, mailchimp_id: remote_list["id"])
  end
  
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
      Interest.find(name: name, category: category) || create_interest(category, name)
    end

    [category, interests]
  end

  # Creates an interest category for a Mailchimp list, given a list ID and a
  # title.
  def create_interest_category(title)
    logger.info "Creating interest category '#{title}'"

    response = find_or_create_remote_interest_category(title)

    Category.create(mailchimp_id: response.body["id"], title: title, list_id: config.list_id)
  end

  def find_or_create_remote_interest_category(title)
    API.lists(config.list_id).interest_categories.create(body: { title: title, type: "hidden" })
  rescue Gibbon::MailChimpError => e
    categories = API.lists(config.list_id).interest_categories.retrieve
      .body["categories"].map { |c| [c["title"], c["id"]] }.to_h

    API.lists(config.list_id).interest_categories(categories[title]).retrieve
  end

  # Creates an interest for a Mailchimp list, given a list ID, a category ID
  # and a name.
  # TODO handle alteration and deletion through the Mailchimp web GUI. Perhaps
  # attempt a GET on the interest path.
  def create_interest(category, name)
    logger.info "Creating interest '#{name}' in category '#{category.title}'"

    response = find_or_create_remote_interest(category.mailchimp_id, name)

    Interest.create(mailchimp_id: response.body["id"], name: name, category: category)
  end

  def find_or_create_remote_interest(category_id, name)
    API.lists(config.list_id).interest_categories(category_id).interests.create(body: { name: name })
  # Dodgy rescue. Can't check for existence in a better way?
  rescue Gibbon::MailChimpError => e
    interests = API.lists(config.list_id).interest_categories(category_id).interests.retrieve
      .body["interests"].map { |i| [i["name"], i["id"]] }.to_h

    API.lists(config.list_id).interest_categories(category_id).interests(interests[name]).retrieve
  end

  def create_fields(fields)
    existing_fields = API.lists(config.list_id).merge_fields
      .retrieve(params: { fields: "merge_fields.name", count: 1000 })
      .body["merge_fields"]
      .map{|i| i["name"]}
      .uniq

    field_names = fields.keys.map(&:to_s)

    new_fields = (field_names - existing_fields).map(&:to_sym)
    if new_fields.empty?
      logger.info "No new fields found"
    else
      logger.info "Found new fields #{new_fields}"
    end

    new_fields.each do |f|
      body = { name: f.to_s, tag: f.to_s }
      if fields[f][:db_type] == "datetime"
        body.merge!({ type: "date", options: { date_format: "dd/mm/yyyy" }})
      else
        body.merge!({ type: "text" })
      end

      logger.info "Syncing new field #{f} as #{body[:type]}"

      API.lists(config.list_id).merge_fields.create(body: body)
    end
  end

  def delete_all_fields
    existing_fields = http_root.lists(config.list_id).merge_fields.retrieve(params: { fields: 'merge_fields.merge_id' }).body["merge_fields"].map{|i| i[:merge_id]}
    existing_fields.each { |i| http_root.lists(config.list_id).merge_fields(i).delete }
  end

  def stale_emails
    return @stale_emails if @stale_emails.present?

    response = EXPORT_API.list(id: config.list_id)

    # NOTE stripping whitespace may be needed in addition to downcasing?
    # Emails in the first column; first row is headers.
    extant_emails = response.map(&:first)[1..-1].compact.map(&:downcase)
    new_emails = @contacts.map { |c| c[:email].downcase }

    @stale_emails = extant_emails - new_emails
  end

  def send_contacts
    operations = contacts.map(&method(:parameterise)).map do |contact|
      {
        method: "PUT",
        path: "lists/#{config.list_id}/members/#{Digest::MD5.hexdigest(contact["email_address"])}",
        body: contact.to_json
      }
    end

    logger.info "#{contacts.size} PUT operations composed"

    if config.purge_stale_emails
      operations += stale_emails.map do |email|
        {
          method: "DELETE",
          path: "lists/#{config.list_id}/members/#{Digest::MD5.hexdigest(email)}"
        }
      end

      logger.info "#{stale_emails.size} DELETE operations composed"
    end

    batch = API.batches.create({
      body: {
        operations: operations
      }
    })

    logger.info "Batch #{batch.body["id"]} starting"

    batch = wait_for(batch.body["id"])

    total = batch.body["total_operations"]
    errors = batch.body["errored_operations"]
    response_body_url = batch.body["response_body_url"]

    logger.info "Batch #{batch.body["id"]} finished, #{errors} errors of #{total} members.  response_body_url: #{response_body_url}"

    batch
  end

  def wait_for(batch_id)
    begin
      response = API.batches(batch_id).retrieve

      return response if response.body["status"] == "finished"
    rescue Gibbon::MailChimpError => err
      logger.error "Gibbon error communicating with Mailchimp: #{err.name}, details in last_error.txt"
      save_error(err)
    end

    sleep 10

    wait_for(batch_id)
  end

  def parameterise(contact)
    {
      "status_if_new" => contact[:subscription_status],
      "status" => contact[:subscription_status],
      "email_address" => contact[:email].downcase,
      "merge_fields" => merge_fields(contact),
      "interests" => interest_fields(contact)
    }
  end

  def merge_fields(contact)
    # Note on Mailchimp default merge fields:
    # FNAME, LNAME, ADDRESS and PHONE are all present on a fresh list.
    result = {}
    contact.slice(*config.merge_fields(contact.keys).map(&:to_sym)).each do |k,v|
      if v.class == Time
        result[k.upcase] = v.to_date
      elsif !v.nil?
        result[k.upcase] = v
      end
    end

    result
  end

  def interest_fields(contact)
    contact.stringify_keys.select { |col| col =~ /^interest/ }.map do |k,v|
      category, name = k.gsub(/^interest/, "").split("$")
      interest = Interest.find_by_list_category_and_name(config.list_id, category, name)

      [interest.mailchimp_id, v==1 ? true : false]
    end.to_h
  end
end