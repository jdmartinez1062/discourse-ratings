# name: discourse-ratings
# about: A Discourse plugin that lets you use topics to rate things
# version: 0.2
# authors: Angus McLeod
# url: https://github.com/paviliondev/discourse-ratings

enabled_site_setting :rating_enabled

register_asset 'stylesheets/common/ratings.scss'
register_asset 'stylesheets/desktop/ratings.scss', :desktop
register_asset 'stylesheets/mobile/ratings.scss', :mobile

if respond_to?(:register_svg_icon)
  register_svg_icon "info"
  register_svg_icon "save"
end

add_admin_route "admin.ratings.settings_page", "ratings"

after_initialize do
  %w[
    ../lib/ratings/engine.rb
    ../lib/ratings/cache.rb
    ../lib/ratings/rating.rb
    ../lib/ratings/rating_type.rb
    ../lib/ratings/object.rb
    ../config/routes.rb
    ../jobs/regular/destroy_rating_type.rb
    ../jobs/regular/destroy_ratings.rb
    ../jobs/regular/migrate_ratings.rb
    ../app/serializers/ratings/object.rb
    ../app/serializers/ratings/rating.rb
    ../app/serializers/ratings/rating_type.rb
    ../app/controllers/ratings/object.rb
    ../app/controllers/ratings/rating.rb
    ../app/controllers/ratings/rating_type.rb
    ../extensions/post_revisor.rb
    ../extensions/posts_controller.rb
    ../extensions/topic.rb
  ].each do |path|
    load File.expand_path(path, __FILE__)
  end
  
  ###### Site ######
  
  add_to_class(:site, :rating_type_names) do 
    map = {}
    DiscourseRatings::RatingType.all.each { |t| map[t.type] = t.name }
    map
  end
  
  add_to_serializer(:site, :rating_type_names) do
    object.rating_type_names
  end
  
  add_to_serializer(:site, :category_rating_types) do
    build_object_list(DiscourseRatings::Object.list('category'))
  end
  
  add_to_serializer(:site, :tag_rating_types) do
    build_object_list(DiscourseRatings::Object.list('tag'))
  end
    
  add_to_class(:site_serializer, :build_object_list) do |list|
    result = {}
    list.each { |obj| result[obj.name] = obj.types }
    result
  end
  
  ###### Category && Tag ######
  
  add_to_class(:category, :rating_types) do
    DiscourseRatings::Object.get('category', full_slug("/"))
  end
  
  add_to_class(:tag, :rating_types) do
    DiscourseRatings::Object.get('tag', name)
  end

  ###### Post ######
  
  add_permitted_post_create_param("ratings")
  
  on(:post_created) do |post, opts, user|
    if opts[:ratings].present?
      begin
        ratings = JSON.parse(opts[:ratings])
      rescue JSON::ParserError
        ratings = []
      end
      
      topic = post.topic
      user_can_rate = topic.user_can_rate(user)
      
      ratings = DiscourseRatings::Rating.build_list(ratings)
        .select { |r| user_can_rate.include?(r.type) }
                  
      if ratings.any?
        post.update_ratings(ratings)
      end
    end
  end
  
  ### These monkey patches are necessary as there is currently
  ### no way to add post attributes on update
   
  class ::PostRevisor
    cattr_accessor :ratings
    prepend PostRevisorRatingsExtension
  end

  ::PostsController.prepend PostsControllerRatingsExtension
  
  on(:post_edited) do |post, topic_changed, revisor|
    if revisor.ratings.present?
      topic = post.topic
      user = post.user
      user_has_rated = topic.user_has_rated(user)
      user_can_rate = topic.user_can_rate(user)

      ratings = DiscourseRatings::Rating.build_list(revisor.ratings)
        .select do |r|
          user_has_rated.include?(r.type) ||
          user_can_rate.include?(r.type)
        end
      
      post.update_ratings(ratings)
      revisor.ratings = nil
    end
  end

  on(:post_destroyed) do |post, opts, user|
    if (ratings = post.ratings).present?
      post.update_ratings(ratings, weight: 0)
    end
  end

  on(:post_recovered) do |post, opts, user|
    if (ratings = post.ratings).present?
      post.update_ratings(ratings)
    end
  end
  
  add_to_class(:post, :ratings) do
    DiscourseRatings::Rating.build_model_list(custom_fields, topic.rating_types)
  end
  
  add_to_class(:post, :update_ratings) do |ratings, weight: 1|
    ratings.each { |rating| rating.weight = weight }
    
    Post.transaction do
      DiscourseRatings::Rating.set_custom_fields(self, ratings)
      save_custom_fields(true)
      update_topic_ratings
    end
    
    push_ratings_to_clients
  end
  
  add_to_class(:post, :update_topic_ratings) do
    types = topic.rating_types
    post_ratings = topic.reload.posts.map { |p| p.ratings }.flatten
        
    return if types.blank? || post_ratings.blank?
        
    types.each do |type|
      type_ratings = post_ratings.select do |r|
        (r.weight === 1) && (r.type === type.to_s)
      end
                  
      if type_ratings.any?    
        sum = type_ratings.map { |r| r.value }.inject(:+)
        count = type_ratings.length
        average = (sum / count).to_f
        
        topic_rating = {
          type: type,
          value: average,
          count: count
        }
        
        DiscourseRatings::Rating.build_and_set(topic, topic_rating)
      end
    end

    topic.save_custom_fields(true)
  end
  
  add_to_class(:post, :push_ratings_to_clients) do
    publish_change_to_clients!("ratings",
      ratings: topic.ratings.as_json,
      user_can_rate: topic.user_can_rate(user)
    )
  end
  
  add_to_serializer(:post, :ratings) do
    DiscourseRatings::Rating.serialize(object.ratings) 
  end
  
  ###### Topic ######
      
  add_to_class(:topic, :ratings) do
    DiscourseRatings::Rating.build_model_list(custom_fields, rating_types)
  end
  
  add_to_class(:topic, :rating_types) do
    types = []
    types.push(category.rating_types) if category.present?
    types.push(tags.map { |tag| tag.rating_types }) if tags.present?
    types.flatten
  end
  
  add_to_class(:topic, :rating_enabled?) do
    SiteSetting.rating_enabled && rating_types.any?
  end
  
  add_to_class(:topic, :user_can_rate) do |user|
    rating_types.select do |type|
      user_has_rated(user).exclude?(type)
    end  
  end
  
  add_to_class(:topic, :user_has_rated) do |user|
    posts.select do |post|
      post.user_id === user.id && post.ratings.present?
    end.map do |post|
      post.ratings.map(&:type)
    end.flatten
  end
  
  add_to_serializer(:topic_view, :ratings) do
    DiscourseRatings::Rating.serialize(object.topic.ratings)
  end

  add_to_serializer(:topic_view, :show_ratings) do
    SiteSetting.rating_topic_average_enabled &&
    object.topic.rating_enabled? && 
    object.topic.ratings.present?
  end
  
  add_to_serializer(:topic_view, :user_can_rate) do
    object.topic.user_can_rate(scope.current_user)
  end
  
  add_to_serializer(:topic_view, :include_user_can_rate?) do
    scope.current_user && object.topic.rating_enabled?
  end
  
  ::Topic.singleton_class.prepend TopicRatingsExtension
  
  add_to_serializer(:topic_list_item, :ratings) do
    DiscourseRatings::Rating.serialize(object.ratings)
  end

  add_to_serializer(:topic_list_item, :show_ratings) do
    SiteSetting.rating_topic_list_average_enabled &&
    object.rating_enabled? && 
    object.ratings.present?
  end
end
