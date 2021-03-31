require 'digest'

class Mailer::Integration::Push < Mailer::Integration
  attr_reader :config, :columns

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

    @remote = OpenStruct.new
  end
  
  def contacts
    return @contacts if defined?(@contacts)
    
    logger.info "Fetching contacts to be synced from database"
    @contacts = if config.since.present?
      # @contacts = DB[config.table].where(config.constraints(read_runtime)).all
      # "table" is a misnomer here, this should really be a view in most cases.
      # email, firstname, lastname are the only mandatory fields IIRC.
      # any other column will either be pushed to a merge field (default)
      # or an interest category (if it has format interestCategory$Interest)
      DB[config.table].where(config.constraints(read_runtime)).all
    else
      DB[config.table].all
    end
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
    
    logger.info "Checking for new fields"
    fields = config.merge_fields(columns)
    fields_w_type = DB.schema(config.table).select { |f| fields.include?(f[0].to_s) }.to_h

    create_fields(fields_w_type) unless contacts.empty?
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
    
    remote_list = find_or_create_remote_list(name)
    
    List.create(name: name, mailchimp_id: remote_list["id"])
  end
  
  def find_or_create_remote_list(name)
    remote_lists = API.lists.retrieve.body["lists"]
    remote_list = remote_lists.find { |l| l["name"] == name }
    
    unless remote_list.present?
      # There are a lot of required properties when creating a list.
      # See the example integration config file.
      settings = config.settings.merge(name: name)
      response = API.lists.create(body: settings)
      
      remote_list = response.body
    end
    
    remote_list
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

    interest_categories.each { |k, v| sync_category_and_interests(k, v) }
  end

  def sync_category_and_interests(category_title, interest_names)
    category = Category.find(list_id: @list.id, title: category_title) ||
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

    Category.create(mailchimp_id: response.body["id"], title: title, list_id: @list.id)
  end

  def find_or_create_remote_interest_category(title)
    API.lists(@list.mailchimp_id).interest_categories.create(body: { title: title, type: "hidden" })
  rescue Gibbon::MailChimpError => e
    categories = API.lists(@list.mailchimp_id).interest_categories.retrieve
      .body["categories"].map { |c| [c["title"], c["id"]] }.to_h

    API.lists(@list.mailchimp_id).interest_categories(categories[title]).retrieve
  end

  # Creates an interest for a Mailchimp list, given a list ID, a category ID
  # and a name.
  # TODO handle alteration and deletion through the Mailchimp web UI. Perhaps
  # attempt a GET on the interest path.
  def create_interest(category, name)
    logger.info "Creating interest '#{name}' in category '#{category.title}'"

    response = find_or_create_remote_interest(category.mailchimp_id, name)

    Interest.create(mailchimp_id: response.body["id"], name: name, category: category)
  end

  def find_or_create_remote_interest(category_id, name)
    API.lists(@list.mailchimp_id).interest_categories(category_id).interests.create(body: { name: name })
  # Dodgy rescue. Can't check for existence in a better way?
  rescue Gibbon::MailChimpError => e
    interests = API.lists(@list.mailchimp_id).interest_categories(category_id).interests.retrieve
      .body["interests"].map { |i| [i["name"], i["id"]] }.to_h

    API.lists(@list.mailchimp_id).interest_categories(category_id).interests(interests[name]).retrieve
  end

  # TODO lean into convention over configuration for the mapping of SQL columns
  # into Mailchimp merge fields.
  # Columns should be snake_case
  # snake_case gets titleized ("Snake Case") for the merge field name
  # The merge field tag is not required on create; and it has a 10 char limit in
  # the UI!
  # Config should be able to override the convention, if needed.
  # The merge field type should be set wherever possible from SQL data types.
  # It may not be possible to do this for certain merge field types: birthday,
  # website, and phone, to give a few examples.
  def create_fields(fields)
    @remote.merge_fields = API.lists(@list.mailchimp_id).merge_fields
      .retrieve(params: { fields: "merge_fields.merge_id,merge_fields.name,merge_fields.tag,merge_fields.type", count: 1000 })
      .body["merge_fields"]
    
    remote_fields = @remote.merge_fields.map { |i| i["name"] }.uniq
    address_field = @remote.merge_fields.find { |i| i["type"] == "address" }

    # By convention, Mailchimp's "name" property on a merge tag is human 
    # friendly. E.g. "First Name" instead of their tag FNAME. Respecting this,
    # column names from the data source will be titleized (and so should be
    # titleizeable), OR manually mapped.
    local_fields = fields.keys.map do |f|
      config.merge_fields_map[f] || f.to_s.titleize(keep_id_suffix: true)
    end
    
    address_fields = config.address_columns.map(&:to_s).map(&:titleize)

    new_fields = (local_fields - remote_fields - address_fields)
    if new_fields.empty?
      logger.info "No new fields found"
    else
      logger.info "Found new fields #{new_fields}"
    end
    
    if address_field.nil?
      logger.info "No address type remote merge tag found! Creating."
      API.lists(@list.mailchimp_id).merge_fields.create({
        name: "Address", tag: "ADDRESS", type: "address"
      })
    end

    new_fields.each do |f|
      column = f.downcase.split.join('_').to_sym
      # We used to set the tag, too, but I think it's better to let the comms 
      # experts have free rein. It could get ugly when we try and set a >10char 
      # tag and it gets truncated.
      body = { name: f }
      # if config.merge_fields_types[f].present?
      #   body.merge!({ type: config.merge_fields_types[f][:type] })
      # Sequel insists on downcasing column headers.
      if fields[column][:db_type] == "datetime"
        body.merge!({ type: "date", options: { date_format: "dd/mm/yyyy" }})
      else
        body.merge!({ type: "text" })
      end

      logger.info "Syncing new field #{f} as #{body[:type]}"

      API.lists(@list.mailchimp_id).merge_fields.create(body: body)
    end
  end

  def delete_all_fields
    existing_fields = http_root.lists(@list.mailchimp_id).merge_fields.retrieve(params: { fields: 'merge_fields.merge_id' }).body["merge_fields"].map{|i| i[:merge_id]}
    existing_fields.each { |i| http_root.lists(@list.mailchimp_id).merge_fields(i).delete }
  end

  def stale_emails
    return @stale_emails if @stale_emails.present?

    response = EXPORT_API.list(id: @list.mailchimp_id)

    # NOTE stripping whitespace may be needed in addition to downcasing?
    # Emails in the first column; first row is headers.
    extant_emails = response.map(&:first)[1..-1].compact.map(&:downcase)
    new_emails = contacts.map { |c| c[:email].downcase }

    @stale_emails = extant_emails - new_emails
  end

  def send_contacts
    operations = contacts.map(&method(:parameterise)).map do |contact|
      {
        method: "PUT",
        path: "lists/#{@list.mailchimp_id}/members/#{Digest::MD5.hexdigest(contact["email_address"])}",
        body: contact.to_json
      }
    end

    logger.info "#{contacts.size} PUT operations composed"

    if config.purge_stale_emails
      operations += stale_emails.map do |email|
        {
          method: "DELETE",
          path: "lists/#{@list.mailchimp_id}/members/#{Digest::MD5.hexdigest(email)}"
        }
      end

      logger.info "#{stale_emails.size} DELETE operations composed"
    end

    batch = API.batches.create(body: {
      operations: operations
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

  # Note the assumption of :email and :subscription_status properties?
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
    # We retrieve and store the remote list merge fields before this point in
    # the sync. This allows the sync to be agnostic about tags (but not about
    # names, sadly) - it looks up the tag using the name.
    
    # How could we be agnostic about tags *AND* names?
    # Mailchimp provides a "merge_id" - an immutable, autoincremented
    # integer that starts from 0 for each list (though 0 is email and not
    # considered a "merge field").
    #
    # 1. We cache the "merge_id" on field creation.
    # 2. We retrieve remote merge fields with the merge_id, name and tag.
    # 3. We look up the tag using the cached merge_id for each field.
    # 4. If a cached merge_id is missing from the remote data, we can re-create.
    # 
    # By using this process we can have a lookup hash sorted out and ready to go
    # for this method long before it ever gets called.
    result = {}
    contact.slice(*config.merge_fields(contact.keys).map(&:to_sym)).each do |k,v|
      merge_field = if config.merge_fields_map.keys.include?(k)
        @remote.merge_fields.find { |f| f["name"] == config.merge_fields_map[k] }
      elsif config.address_columns.include?(k)
        @remote.merge_fields.find { |f| f["type"] == "address" }
      else
        @remote.merge_fields.find { |f| f["name"] == k.to_s.titleize(keep_id_suffix: true) }
      end
      
      merge_field_tag = merge_field["tag"] unless merge_field.nil?
      
      if merge_field["type"] == "address" && !v.nil?
        result[merge_field_tag] = result[merge_field_tag].to_h.merge({ config.address_fields_map[k] => v })
      elsif !merge_field_tag.nil?
        if v.class == Time
          result[merge_field_tag] = v.utc.iso8601
        elsif !v.nil?
          result[merge_field_tag] = v
        end
      end
    end

    result
  end

  def interest_fields(contact)
    contact.stringify_keys.select { |col| col =~ /^interest/ }.map do |k,v|
      category, name = k.gsub(/^interest/, "").split("$")
      interest = Interest.find_by_list_category_and_name(@list, category, name)

      # Sequel gets bit columns as true/false.
      [interest.mailchimp_id, v]
    end.to_h
  end
end
