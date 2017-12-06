# name: discourse-solved
# about: Custom discourse solved plugin based on https://github.com/discourse/discourse-solved
# version: 0.5
# authors: Muhlis Budi Cahyono (muhlisbc@gmail.com)
# url: http://git.dev.abylina.com/momon/discourse-solved

enabled_site_setting :solved_enabled

PLUGIN_NAME = "discourse_solved".freeze

register_asset 'stylesheets/solutions.scss'

after_initialize do

  # we got to do a one time upgrade
  if defined?(UserAction::SOLVED)
    unless $redis.get('solved_already_upgraded')
      unless UserAction.where(action_type: UserAction::SOLVED).exists?
        Rails.logger.info("Upgrading storage for solved")
        sql = <<SQL
        INSERT INTO user_actions(action_type,
                                 user_id,
                                 target_topic_id,
                                 target_post_id,
                                 acting_user_id,
                                 created_at,
                                 updated_at)
        SELECT :solved,
               p.user_id,
               p.topic_id,
               p.id,
               t.user_id,
               pc.created_at,
               pc.updated_at
        FROM
          post_custom_fields pc
        JOIN
          posts p ON p.id = pc.post_id
        JOIN
          topics t ON t.id = p.topic_id
        WHERE
          pc.name = 'is_accepted_answer' AND
          pc.value = 'true' AND
          p.user_id IS NOT NULL
SQL

        UserAction.exec_sql(sql, solved: UserAction::SOLVED)
      end
      $redis.set("solved_already_upgraded", "true")
    end
  end

  module ::DiscourseSolved
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseSolved
    end
  end

  require_dependency "application_controller"
  class DiscourseSolved::AnswerController < ::ApplicationController

    def index
      guardian.ensure_can_process_answers!
      post_ids = PostCustomField.where(name: 'is_queued_answer', value: 'true').pluck(:post_id)
      posts = Post.where(id: post_ids).includes(:topic, :user).references(:topic)
      render_json_dump(serialize_data(posts, SolvedPostQueueSerializer, scope: guardian, add_title: true, root: false))
    end

    def accept

      limit_accepts

      post = Post.find(params[:id].to_i)
      topic = post.topic

      guardian.ensure_can_accept_answer!(topic)

      accepted_ids = topic.custom_fields["accepted_answer_post_ids"].to_s.split(",").map(&:to_i)

      accepted_ids << post.id

      post.custom_fields["is_accepted_answer"]        = "true"
      post.custom_fields["is_queued_answer"]          = "accepted"
      topic.custom_fields["accepted_answer_post_ids"] = accepted_ids.uniq.join(",")

      if !topic.custom_fields["mmn_queue_state"].blank?
        topic.custom_fields["mmn_queue_state"] = nil
      end

      if topic.custom_fields["mmn_button_active"].blank?
        topic.custom_fields["solved_state"] = nil
      end

      topic.save!
      post.save!

      if defined?(UserAction::SOLVED)
        UserAction.log_action!(
          action_type: UserAction::SOLVED,
          user_id: post.user_id,
          acting_user_id: guardian.user.id,
          target_post_id: post.id,
          target_topic_id: post.topic_id
        )
      end

      unless current_user.id == post.user_id
        Notification.create!(
          notification_type: Notification.types[:custom],
          user_id: post.user_id,
          topic_id: post.topic_id,
          post_number: post.post_number,
          data: {
            message: 'solved.accepted_notification',
            display_username: current_user.username,
            topic_title: topic.title
          }.to_json
        )
      end

      if (auto_close_hours = SiteSetting.solved_topics_auto_close_hours) > (0) && !topic.closed
        topic.set_or_create_timer(
          TopicTimer.types[:close],
          auto_close_hours,
          based_on_last_post: true
        )

        MessageBus.publish("/topic/#{topic.id}", reload_topic: true)
      end

      DiscourseEvent.trigger(:accepted_solution, post)
      render json: success_json
    end

    def unaccept

      limit_accepts

      post = Post.find(params[:id].to_i)

      topic = post.topic

      guardian.ensure_can_accept_answer!(post.topic)

      post.custom_fields["is_accepted_answer"] = nil
      post.custom_fields["is_queued_answer"] = nil

      accepted_ids = topic.custom_fields["accepted_answer_post_ids"].split(",").map(&:to_i)
      accepted_ids.delete(post.id)
      accepted_ids = accepted_ids.length > 0 ? accepted_ids.uniq.join(",") : nil

      topic.custom_fields["accepted_answer_post_ids"] = accepted_ids

      if accepted_ids.nil? && topic.custom_fields["solved_state"] == "solved"
        topic.custom_fields["mmn_queue_state"] = "solved"
      end

      if accepted_ids.blank? && topic.custom_fields["mmn_button_active"].blank?
        topic.custom_fields["solved_state"] = nil
      end

      topic.save!
      post.save!

      # TODO remove_action! does not allow for this type of interface
      if defined? UserAction::SOLVED
        UserAction.where(
          action_type: UserAction::SOLVED,
          target_post_id: post.id
        ).destroy_all
      end

      # yank notification
      notification = Notification.find_by(
         notification_type: Notification.types[:custom],
         user_id: post.user_id,
         topic_id: post.topic_id,
         post_number: post.post_number
      )

      notification.destroy if notification

      DiscourseEvent.trigger(:unaccepted_solution, post)

      render json: success_json
    end

    def queue
      limit_accepts

      post = Post.find(params[:id].to_i)

      guardian.ensure_can_queue_answer!(post.topic)

      post.custom_fields["is_queued_answer"] = "true"
      post.custom_fields["queued_by"] = current_user.id
      post.save!

      render json: success_json
    end

    def unqueue
      limit_accepts

      post = Post.find(params[:id].to_i)

      guardian.ensure_can_queue_answer!(post.topic)

      post.custom_fields["is_queued_answer"] = nil
      post.save!

      render json: success_json
    end

    def reject
      limit_accepts

      post = Post.find(params[:id].to_i)

      guardian.ensure_can_accept_answer!(post.topic)

      post.custom_fields["is_queued_answer"] = nil
      post.save!

      render json: success_json
    end

    def is_show_link
      can_see = current_user && current_user.groups.pluck(:name).include?(SiteSetting.solved_group_can_see_queue_page)
      render json: {show_link: can_see}
    end

    def limit_accepts
      unless current_user.staff?
        RateLimiter.new(nil, "accept-hr-#{current_user.id}", 20, 1.hour).performed!
        RateLimiter.new(nil, "accept-min-#{current_user.id}", 4, 30.seconds).performed!
      end
    end
  end

  DiscourseSolved::Engine.routes.draw do
    get "/index"      => "answer#index"
    post "/accept"    => "answer#accept"
    post "/unaccept"  => "answer#unaccept"
    post "/queue"     => "answer#queue"
    post "/unqueue"   => "answer#unqueue"
    post "/reject"    => "answer#reject"
    get "/is_show_link" => "answer#is_show_link"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseSolved::Engine, at: "solution"
  end

  TopicView.add_post_custom_fields_whitelister do |user|
    ["is_accepted_answer", "is_queued_answer"]
  end

  if Report.respond_to?(:add_report)
    AdminDashboardData::GLOBAL_REPORTS << "accepted_solutions"

    Report.add_report("accepted_solutions") do |report|
      report.data = []
      accepted_solutions = TopicCustomField.where(name: "accepted_answer_post_ids")
      accepted_solutions = accepted_solutions.joins(:topic).where("topics.category_id = ?", report.category_id) if report.category_id
      accepted_solutions.where("topic_custom_fields.created_at >= ?", report.start_date)
        .where("topic_custom_fields.created_at <= ?", report.end_date)
        .group("DATE(topic_custom_fields.created_at)")
        .order("DATE(topic_custom_fields.created_at)")
        .count
        .each do |date, count|
        report.data << { x: date, y: count }
      end
      report.total = accepted_solutions.count
      report.prev30Days = accepted_solutions.where("topic_custom_fields.created_at >= ?", report.start_date - 30.days)
        .where("topic_custom_fields.created_at <= ?", report.start_date)
        .count
    end
  end

  if defined?(UserAction::SOLVED)
    require_dependency 'user_summary'
    class ::UserSummary
      def solved_count
        UserAction
          .where(user: @user)
          .where(action_type: UserAction::SOLVED)
          .count
      end
    end

    require_dependency 'user_summary_serializer'
    class ::UserSummarySerializer
      attributes :solved_count

      def solved_count
        object.solved_count
      end
    end
  end

  require_dependency 'topic_view_serializer'
  class ::TopicViewSerializer
    attributes :accepted_answers

    def include_accepted_answer?
      accepted_answer_post_ids
    end

    def accepted_answers
      if infos = accepted_answer_post_info
        infos.map do |info|
          {
            post_number: info[0],
            username: info[1],
            excerpt: info[2]
          }
        end
      end
    end

    def accepted_answer_post_info
      # TODO: we may already have it in the stream ... so bypass query here
      postInfos = Post.where(id: accepted_answer_post_ids, topic_id: object.topic.id)
        .joins(:user)
        .pluck('post_number', 'username', 'cooked')

      if postInfos.length > 0
        postInfos.each do |postInfo|
          postInfo[2] = if SiteSetting.solved_quote_length > 0
            PrettyText.excerpt(postInfo[2], SiteSetting.solved_quote_length)
          else
            nil
          end
        end
        return postInfos
      end
    end

    def accepted_answer_post_ids
      ids = object.topic.custom_fields["accepted_answer_post_ids"]
      ids ? ids.to_s.split(",").map(&:to_i) : nil
    end

  end

  class ::Category
    after_save :reset_accepted_cache

    protected
    def reset_accepted_cache
      ::Guardian.reset_accepted_answer_cache
    end
  end

  class ::Guardian

    @@allowed_accepted_cache = DistributedCache.new("allowed_accepted")

    def self.reset_accepted_answer_cache
      @@allowed_accepted_cache["allowed"] =
        begin
          Set.new(
            CategoryCustomField
              .where(name: "enable_accepted_answers", value: "true")
              .pluck(:category_id)
          )
        end
    end

    def allow_accepted_answers_on_category?(category_id)
      return true if SiteSetting.allow_solved_on_all_topics

      self.class.reset_accepted_answer_cache unless @@allowed_accepted_cache["allowed"]
      @@allowed_accepted_cache["allowed"].include?(category_id)
    end

    def can_accept_answer?(topic)
      # allow_accepted_answers_on_category?(topic.category_id) && (
      #   is_staff? || (
      #     authenticated? && ((!topic.closed? && topic.user_id == current_user.id) ||
      #                       (current_user.trust_level >= SiteSetting.accept_all_solutions_trust_level))
      #   )
      # )

      allow_accepted_answers_on_category?(topic.category_id) && is_admin?
    end

    def user_group_names
      @user_group_names ||= current_user.groups.pluck(:name)
    end

    def can_queue_answer?(topic)
      allow_accepted_answers_on_category?(topic.category_id) && (
        is_admin? || (
          authenticated? && (
                              (!topic.closed? && topic.user_id == current_user.id) ||
                              (current_user.trust_level >= 4) ||
                              (user_group_names & SiteSetting.solved_groups_can_queue.to_s.split("|")).length > 0
                            )
        )
      )      
    end

    def can_process_answers?
      is_staff?
    end
  end

  require_dependency 'post_serializer'
  class ::PostSerializer
    attributes :can_accept_answer, :can_unaccept_answer, :accepted_answer, :can_queue_answer, :can_reject_answer, :is_queued_answer

    def can_accept_answer
      if topic = get_topic
        return scope.can_accept_answer?(topic) && object.post_number > 1 && !accepted_answer
      end
      false
    end

    def can_unaccept_answer
      if topic = get_topic
        return scope.can_accept_answer?(topic) && (post_custom_fields["is_accepted_answer"] == 'true')
      end
    end

    def accepted_answer
      post_custom_fields["is_accepted_answer"] == 'true'
    end

    def is_queued_answer
      post_custom_fields["is_queued_answer"]
    end

    def can_queue_answer
      if topic = get_topic
        return scope.can_queue_answer?(topic) && object.post_number > 1 && !accepted_answer && post_custom_fields["is_queued_answer"].nil?
      end
    end

    def can_reject_answer
      if topic = get_topic
        return scope.can_queue_answer?(topic) && object.post_number > 1 && !accepted_answer && post_custom_fields["is_queued_answer"] == "true"
      end
    end

    def get_topic
      (topic_view && topic_view.topic) || object.topic
    end
  end

  class SolvedPostQueueSerializer < ::PostSerializer
    attributes :total_post_count, :queued_by, :solution_count, :queue_count

    def total_post_count
      object.topic ? object.topic.posts.count : 0
    end

    def queued_by
      if user = User.where(id: object.custom_fields["queued_by"].to_i).first
        user.username
      end
    end

    def solution_count
      if topic = object.topic
        topic.custom_fields["accepted_answer_post_ids"].to_s.split(",").length
      end
    end

    def queue_count
      if topic = object.topic
        ids = object.topic.posts.pluck(:id)
        PostCustomField.where(post_id: ids, name: 'is_queued_answer', value: 'true').count
      end
    end
  end

  # Custom helper
  module ::MmnCustomHelper
    def self.included(base)
      base.class_eval {
        #attributes :has_accepted_answer, :can_have_answer
        attributes :can_have_answer

        # def has_accepted_answer
        #   object.custom_fields["accepted_answer_post_ids"] ? true : false
        # end

        def can_have_answer
          return true if SiteSetting.allow_solved_on_all_topics
          return false if object.closed || object.archived
          return scope.allow_accepted_answers_on_category?(object.category_id)
        end

        def include_can_have_answer?
          SiteSetting.empty_box_on_unsolved
        end
      }
    end

    # def self.topic_custom_query(is_not = "")
    #   "topics.id #{is_not} IN (SELECT tc.topic_id FROM topic_custom_fields tc WHERE tc.name = 'accepted_answer_post_ids' AND tc.value IS NOT NULL)"
    # end
  end

  # require_dependency 'search'

  # if Search.respond_to? :advanced_filter
  #   Search.advanced_filter(/in:solved/) do |posts|
  #     posts.where(::MmnCustomHelper.topic_custom_query)
  #   end

  #   Search.advanced_filter(/in:unsolved/) do |posts|
  #     posts.where(::MmnCustomHelper.topic_custom_query("NOT"))
  #   end
  # end

  # if Discourse.has_needed_version?(Discourse::VERSION::STRING, '1.8.0.beta6')
  #   require_dependency 'topic_query'

  #   TopicQuery.add_custom_filter(:solved) do |results, topic_query|
  #     if topic_query.options[:solved] == 'yes'
  #       results = results.where(::MmnCustomHelper.topic_custom_query)
  #     elsif topic_query.options[:solved] == 'no'
  #       results = results.where(::MmnCustomHelper.topic_custom_query("NOT"))
  #     end
  #     results
  #   end
  # end

  require_dependency 'topic_list_item_serializer'
  require_dependency 'listable_topic_serializer'

  ::TopicListItemSerializer.send(:include, MmnCustomHelper)
  ::ListableTopicSerializer.send(:include, MmnCustomHelper)

  TopicList.preloaded_custom_fields << "accepted_answer_post_ids" if TopicList.respond_to? :preloaded_custom_fields

  if CategoryList.respond_to?(:preloaded_topic_custom_fields)
    CategoryList.preloaded_topic_custom_fields << "accepted_answer_post_ids"
  end

end