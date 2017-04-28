class Mailer::Integration::Pull < Mailer::Integration
  def initialize(path)
    if path.directory?
      @base_dir = path
    else
      raise ArgumentError, "#{path} is not a directory"
    end

    # Some dastardly metaprogramming to set up some Sequel models from a user-supplied config file. Within the Pull class, we can use ::Campaign, ::Subscriber, and ::Junction when needed.
    ["campaign", "subscriber", "junction"].each do |m|
      # 'Dataset' in this case means table name - as defined in your config file.
      dataset = ::PULL_CONFIG[m.to_sym][:name].downcase.to_sym

      # Define a new Sequel::Model that looks up the table/dataset determined above.
      klass = Class.new(Sequel::Model(dataset)) do
        # The config file defines the assocations e.g. many-to-one between tables.
        ::PULL_CONFIG[m.to_sym][:associations].each do |assoc|
          # If your tables don't conform to Sequel conventions, you'll need to pass in some opts to get the foreign keys etc. right.
          method(assoc[:type]).call(assoc[:model], assoc[:opts])
        end
      end

      # a few alternatives here, depending on namespace preferences. because namespacing has been killing me lately, I'm putting them up high, but this should probably be reconsidered when time permits.
      # This gives global classes Campaign, Subscriber and Junction.
      Object.const_set(m.capitalize, klass)
    end
  end

  def run!
    logger.info "BEGINNING SYNC FROM MAILER"

    @this_run = Time.now
    # previous month, i.e., around 30 days ago. have to make a call here about where to cut the long tail off.
    # 30 days is short, but definitely long enough to not miss out on a lot.
    # Note Date#<< and DateTime#<< both shift the month backwards in time.
    filter = (read_runtime << 1).iso8601

    begin
      sync_campaigns(filter: filter)

      logger.info "Finished, saving this run as complete"
      save_runtime(@this_run)
    rescue Exception => err
      logger.error "#{err.class}: #{err.message}"
      logger.error err.backtrace
    ensure
      logger.close
    end
  end

  # Get campaigns, starting with the oldest. For each campaign, call sync_campaign.
  def sync_campaigns(opts={})
    offset = opts[:offset] ||= 0

    logger.info "REQUESTING RECORDS #{offset} - #{offset + 9}"
    response = list_campaigns(offset, opts[:filter])

    response.body["campaigns"].each do |campaign|
      sync_campaign(campaign)
    end

    unless response.body["total_items"] < (offset + 10) # 10 per request by default on campaigns
      sync_campaigns(offset: offset + 10, filter: opts[:filter])
    end
  end

  # Get the campaign data (with an additional request for content a.k.a. message
  # body). Find or save it. Then get email activity for the campaign, sort
  # emails into open/click/bounce/unsubscribe lists, and sync the contacts back
  # to the database.
  def sync_campaign(campaign)
    logger.info "STARTING SYNC FOR CAMPAIGN #{campaign["settings"]["title"].upcase}"

    content = (::API.campaigns(campaign["id"]).content.retrieve).body
    # TODO test if this pattern holds for non-regular campaigns (e.g. A/B tests, plaintext campaigns)
    message = (content["plain_text"] || content["html"]).gsub(/(?<!\r)\n/, "\r\n")

    # store message to the database.
    @campaign = ::Campaign.find(CAMPAIGN[:campaign_id] => "mailchimp_#{campaign["id"]}") ||
      ::Campaign.new({
        CAMPAIGN[:campaign_id] => "mailchimp_#{campaign["id"]}",
        CAMPAIGN[:message_subject] => campaign["settings"]["subject_line"],
        CAMPAIGN[:message_text] => message,
        CAMPAIGN[:message_send_date] => campaign["send_time"],
        CAMPAIGN[:message_create_date] => campaign["send_time"]
      }.merge(CAMPAIGN[:static_cols] || {}))

    if @campaign.save
      # Get email activity
      active_emails = get_campaign_activity(campaign["id"])

      sync_email_activity(active_emails)
    end
  end

  def timer
    elapsed = Time.now - @timestamp
    @timestamp = Time.now

    elapsed
  end

  # Watch count vs. size. Can't call size on Sequel datasets. (Alias it?)
  # has grown a little out of hand. but it remains fairly DRY.
  def sync_contacts(emails, health, campaign)
    logger.info "Performing batch sync with #{emails.size} emails, starting at " +
      "#{@timestamp = Time.now}"

    # subscribers = ::Subscriber.where(SUBSCRIBER[:email] => emails)
    # sec_subscribers = ::Subscriber.where(SUBSCRIBER[:secondary_email] => emails)
    junction = ::Junction.where(campaign: campaign)
    logger.debug "Queries composed in #{timer}"

    # For each pair of relevant columns, look up and update subscribers who match an email.
    [{ email: :email, health: :health }, { email: :secondary_email, health: :secondary_health }].each do |e|
      subscribers = ::Subscriber.where(SUBSCRIBER[e[:email]] => emails)

      # Update junction records and subscribers, unless they're unsubscribed, with the latest health.
      subscriber_updates = subscribers.exclude(SUBSCRIBER[e[:health]] => ["unsubscribed", health]).update(SUBSCRIBER[e[:health]] => health)
      logger.info "Updated email health on #{subscriber_updates} Subscribers in #{timer}"

      # Update receipt status on the junction records by inner joining to subscribers
      junction_updates = junction.join(subscribers, JUNCTION[:subscriber_key] => SUBSCRIBER[:key]).exclude(JUNCTION[:receipt] => health).update(JUNCTION[:receipt] => health)
      logger.info "Updated receipt status on #{junction_updates} junction rows in #{timer}"

      # Create joins thru the junction table, where there are none yet. Note Sequel's double-underscore convention - shorthand for specifying explicitly the table and column to avoid ambiguity errors. Also note Sequel's t# convention - joined tables are aliased as t1, t2, etc.
      inserts = subscribers.left_join(junction, SUBSCRIBER[:key] => JUNCTION[:subscriber_key]).where("t1__#{JUNCTION[:campaign_key]}".to_sym => nil).select("#{JUNCTION[:subscriber]}__#{SUBSCRIBER[:key]}".to_sym).distinct.map { |c| [c[SUBSCRIBER[:key]], campaign[CAMPAIGN[:key]], *(JUNCTION[:static_cols] || {}).values, health] }
      logger.debug "Composed insert in #{timer}, now executing"

      # And insert them in a batch
      ::Junction.import([JUNCTION[:subscriber_key], JUNCTION[:campaign_key], *(JUNCTION[:static_cols] || {}).keys, JUNCTION[:receipt]], inserts)
      logger.info "Inserted #{inserts.size} new rows to the ContactRec table in #{timer}"
    end
  end

  private
  def sync_email_activity(active_emails)
    # Sort into lists by action, and sync back to our database in batches
    action_lists = {}

    active_emails.each do |email|
      actions = email["activity"].collect { |activity| activity["action"] }

      (action_lists[action_with_priority(actions)] ||= []) << email["email_address"]
    end

    action_lists.each do |action, emails|
      emails.each_slice(::APP_CONFIG[:subset]) { |s| sync_contacts(s, action, @campaign) }
    end
  end

  # This method sets action priority and also maps Mailchimp action keywords to
  # our legacy keywords.
  def action_with_priority(actions)
    return "unsubscribed" if actions.include?("unsubscribe")
    return "forwarded"    if actions.include?("forward")
    return "clicked"      if actions.include?("click")
    return "opened"       if actions.include?("open")
    return "bounced"      if actions.include?("bounce")
  end

  def get_campaign_activity(campaign_id, active_emails=[], offset=0)
    response = ::API.reports(campaign_id).email_activity.retrieve(params: { offset: offset })
    active_emails = active_emails | response.body["emails"]

    if response.body["total_items"] < offset + 10
      active_emails
    else
      get_campaign_activity(campaign_id, active_emails, offset + 10)
    end
  end

  def action_lookup
    { "open" => "opened", "click" => "clicked", "bounce" => "bounced", "unsubscribe" => "unsubscribed", "forward" => "forwarded" }
  end

  ## Methods below are for instantiating request objects to the mailer ::API.
  def list_campaigns(offset, since = nil)
    params = {
      list_id: ::PULL_CONFIG[:list_id], status: "sent", offset: offset,
      sort_field: "send_time", sort_dir: "ASC"
    }

    if since
      params[:since_send_time] = since
    end
    # returning 2015-12-14 - what the fuck. glad I went with the above version, but slightly in awe that I even came up with something so dense. -kbuckley
    # was gunning for impenetrability with this version:
    #params.[]=(*since ? [:filters,{ldate_since_datetime: since}] : [:ids,"all"])

    ::API.campaigns.retrieve(params: params)
  end
end
