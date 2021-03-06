# name: discourse-elections
# about: Run elections in Discourse
# version: 0.2
# authors: angus

register_asset 'stylesheets/common/elections.scss'
register_asset 'stylesheets/desktop/elections.scss', :desktop
register_asset 'stylesheets/mobile/elections.scss', :mobile

after_initialize do
  Topic.register_custom_field_type('election_self_nomination_allowed', :boolean)
  Topic.register_custom_field_type('election_nominations', :integer)
  Topic.register_custom_field_type('election_status', :integer)
  add_to_serializer(:topic_view, :election_status) {object.topic.election_status}
  add_to_serializer(:topic_view, :election_position) {object.topic.custom_fields['election_position']}
  add_to_serializer(:topic_view, :election_nominations) {object.topic.election_nominations}
  add_to_serializer(:topic_view, :election_nominations_usernames) {object.topic.election_nominations_usernames}
  add_to_serializer(:topic_view, :election_self_nomination_allowed) {object.topic.custom_fields['election_self_nomination_allowed']}
  add_to_serializer(:topic_view, :subtype) {object.topic.subtype}
  add_to_serializer(:topic_view, :election_is_nominee) {
    scope.user && object.topic.election_nominations.include?(scope.user.id)
  }
  add_to_serializer(:topic_view, :election_nomination_statements) {object.topic.election_nomination_statements}
  add_to_serializer(:topic_view, :election_made_statement) {
    if scope.user
      object.topic.election_nomination_statements.any?{|n| n['user_id'] == scope.user.id}
    end
  }
  add_to_serializer(:topic_view, :election_nomination_message) {object.topic.custom_fields['election_nomination_message']}
  add_to_serializer(:topic_view, :election_poll_message) {object.topic.custom_fields['election_poll_message']}
  add_to_serializer(:topic_view, :election_same_message) {object.topic.custom_fields['election_poll_message']}

  Category.register_custom_field_type('for_elections', :boolean)
  add_to_serializer(:basic_category, :for_elections) {object.custom_fields["for_elections"]}

  Post.register_custom_field_type('election_nomination_statement', :boolean)
  add_to_serializer(:post, :election_post) {object.is_first_post?}
  add_to_serializer(:post, :election_nomination_statement) {object.custom_fields["election_nomination_statement"]}
  add_to_serializer(:post, :election_nominee_title) {
    object.user && object.user.election_nominations && object.user.election_nominee_title
  }
  add_to_serializer(:post, :election_by_nominee) {
    object.user && object.topic.election_nominations.include?(object.user.id)
  }
  PostRevisor.track_topic_field(:election_nomination_statement)

  add_to_serializer(:current_user, :is_elections_admin) {object.is_elections_admin?}

  require_dependency "application_controller"
  module ::DiscourseElections
    class Engine < ::Rails::Engine
      engine_name "discourse_elections"
      isolate_namespace DiscourseElections
    end
  end

  DiscourseElections::Engine.routes.draw do
    post "nomination/set-by-username" => "nomination#set_by_username"
    post "nomination" => "nomination#add"
    delete "nomination" => "nomination#remove"

    post "create" =>"election#create"
    put "set-self-nomination" => "election#set_self_nomination"
    put "set-message" => "election#set_message"
    put "set-status" => "election#set_status"
    put "set-position" => "election#set_position"
    put "start-poll" => "election#start_poll"

    get "category-list" => "election_list#category_list"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseElections::Engine, at: "election"
  end

  load File.expand_path('../controllers/election.rb', __FILE__)
  load File.expand_path('../controllers/election_list.rb', __FILE__)
  load File.expand_path('../controllers/nomination.rb', __FILE__)
  load File.expand_path('../serializers/election.rb', __FILE__)
  load File.expand_path('../jobs/notify_nominees.rb', __FILE__)
  load File.expand_path('../lib/election_post.rb', __FILE__)
  load File.expand_path('../lib/election_topic.rb', __FILE__)
  load File.expand_path('../lib/nomination_statement.rb', __FILE__)
  load File.expand_path('../lib/nomination.rb', __FILE__)

  ApplicationController.class_eval do
    def ensure_is_elections_admin
      raise Discourse::InvalidAccess.new unless current_user && current_user.is_elections_admin?
    end

    def ensure_is_elections_category
      return false unless params.include?(:category_id)

      category = Category.find(params[:category_id])
      unless category.custom_fields["for_elections"]
        raise StandardError.new I18n.t("election.errors.category_not_enabled")
      end
    end
  end

  User.class_eval do
    def is_elections_admin?
      if SiteSetting.elections_admin_moderator
        staff?
      else
        admin?
      end
    end

    def election_nominations
      TopicCustomField.where(name: 'election_nominations', value: self.id).pluck(:topic_id) || []
    end

    def election_nominee_title
      if election_nominations.any?
        topic = Topic.find(election_nominations[0])
        I18n.t('election.post.nominee_title', {
          url: topic.url,
          position: topic.custom_fields['election_position']
        })
      end
    end
  end

  PostCustomField.class_eval do
    after_save :update_election_status, if: :polls_updated

    def polls_updated
      self.name == 'polls'
    end

    def update_election_status
      poll = JSON.parse(self.value)["poll"]
      post = Post.find(self.post_id)
      result = nil
      new_status = nil

      if poll["status"] == 'closed' && post.topic.election_status == Topic.election_statuses[:poll]
        new_status = Topic.election_statuses[:closed_poll]
      end

      if poll["status"] == 'open' && post.topic.election_status == Topic.election_statuses[:closed_poll]
        new_status = Topic.election_statuses[:poll]
      end

      if new_status
        result = DiscourseElections::ElectionTopic.set_status(post.topic_id, new_status)

        if result
          MessageBus.publish("/topic/#{post.topic.id}", reload_topic: true)
        end
      end
    end
  end

  Topic.class_eval do
    attr_accessor :election_status_changed
    after_save :handle_election_status_change, if: :election_status_changed

    def election_status
      self.custom_fields['election_status']
    end

    def handle_election_status_change
      if election_status.to_i == Topic.election_statuses[:poll]
        message = I18n.t('election.notification.poll', title: self.title)
        notify_nominees(message)
      end

      if election_status.to_i == Topic.election_statuses[:closed_poll]
        message = I18n.t('election.notification.closed_poll', title: self.title)
        notify_nominees(message)
      end

      election_status_changed = false
    end

    def notify_nominees(message)
      Jobs.enqueue(:notify_nominees, topic_id: self.id, message: message)
    end

    def election_nominations
      if self.custom_fields["election_nominations"]
        [*self.custom_fields["election_nominations"]]
      else
        []
      end
    end

    def election_nominations_usernames
      if election_nominations.any?
        usernames = []
        election_nominations.each do |user_id|
          if user_id
            usernames.push(User.find(user_id).username)
          end
        end
        usernames
      else
        []
      end
    end

    def election_nomination_statements
      if self.custom_fields["election_nomination_statements"]
        JSON.parse(self.custom_fields["election_nomination_statements"])
      else
        []
      end
    end

    def self.election_statuses
      @types ||= Enum.new(nomination: 1,
                          poll: 2,
                          closed_poll: 3
                         )
    end
  end

  NewPostManager.add_handler do |manager|
    if manager.args[:topic_id]
      topic = Topic.find(manager.args[:topic_id])

      # do nothing if first post in topic
      if topic.subtype === 'election' && topic.try(:highest_post_number) != 0
        extracted_polls = DiscoursePoll::Poll::extract(manager.args[:raw], manager.args[:topic_id], manager.user[:id])

        if extracted_polls.length > 0
          result = NewPostResult.new(:poll, false)
          result.errors[:base] = I18n.t("election.errors.seperate_poll")
          result
        end
      end
    end
  end

  validate(:post, :validate_election_polls) do |force = nil|
    return unless self.raw_changed?
    return if self.is_first_post?

    extracted_polls = DiscoursePoll::Poll::extract(self.raw, self.topic_id, self.user_id)

    if extracted_polls.length > 0
      self.errors.add(:base, I18n.t("election.errors.seperate_poll"))
    end
  end

  DiscourseEvent.on(:post_created) do |post, opts, user|
    if opts[:election_nomination_statement] && post.topic.election_nominations.include?(user.id)
      post.custom_fields['election_nomination_statement'] = opts[:election_nomination_statement]
      post.save

      DiscourseElections::NominationStatement.update(post)
    end
  end

  DiscourseEvent.on(:post_edited) do |post, topic_changed|
    user = User.find(post.user_id)
    if post.custom_fields['election_nomination_statement'] && post.topic.election_nominations.include?(user.id)
      DiscourseElections::NominationStatement.update(post)
    end
  end

  DiscourseEvent.on(:post_destroyed) do |post, opts, user|
    if post.custom_fields['election_nomination_statement'] && post.topic.election_nominations.include?(user.id)
      DiscourseElections::NominationStatement.update(post)
    end
  end

  DiscourseEvent.on(:post_recovered) do |post, opts, user|
    if post.custom_fields['election_nomination_statement'] && post.topic.election_nominations.include?(user.id)
      DiscourseElections::NominationStatement.update(post)
    end
  end
end
