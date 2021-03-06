module Hobo

  module ModelController

    include Hobo::Controller

    VIEWLIB_DIR = "taglibs"

    DONT_PAGINATE_FORMATS = [ Mime::CSV, Mime::YAML, Mime::JSON, Mime::XML, Mime::ATOM, Mime::RSS ]

    READ_ONLY_ACTIONS  = [:index, :show]
    WRITE_ONLY_ACTIONS = [:create, :update, :destroy]
    FORM_ACTIONS       = [:new, :edit]

    class << self

      def included(base)
        base.class_eval do
          @auto_actions ||= {}

          inheriting_cattr_reader :web_methods => [], :show_actions => [], :index_actions => [], 
                                  :owner_actions => {}

          extend ClassMethods


          helper_method :model, :current_user
          before_filter :set_no_cache_headers

          rescue_from ActiveRecord::RecordNotFound, :with => :not_found

          rescue_from Hobo::Model::PermissionDeniedError,  :with => :permission_denied
          rescue_from Hobo::Lifecycles::LifecycleKeyError, :with => :permission_denied

          alias_method_chain :render, :hobo_model

        end
        register_controller(base)

        Hobo::Controller.included_in_class(base)
      end

    end
    
    
    def self.register_controller(controller)
      @controller_names ||= Set.new
      @controller_names << controller.name
    end
    
    
    def self.all_controllers(subsite=nil, force=false)
      # Load every controller in app/controllers/<subsite>...
      @controllers_loaded ||= {}
      if force || !@controllers_loaded[subsite]
        dir = "#{RAILS_ROOT}/app/controllers#{'/' + subsite if subsite}"
        Dir.entries(dir).each do |f|
          f =~ /^[a-zA-Z_][a-zA-Z0-9_]*_controller\.rb$/ and f.sub(/.rb$/, '').camelize.constantize
        end
        @controllers_loaded[subsite] = true
      end
      
      # ...but only return the ones that registered themselves
      names = (@controller_names || []).select { |n| subsite ? n =~ /^#{subsite.camelize}::/ : n !~ /::/ }
      
      names.map do |name|
        begin
          name.constantize
        rescue NameError
          @controller_names.delete name
          nil
        end
      end.compact
    end
    


    module ClassMethods

      attr_writer :model

      def model
        @model ||= name.sub(/Controller$/, "").singularize.constantize
      end


      def autocomplete(name, options={}, &block)
        options = options.dup
        field = options.delete(:field) || name
        if block
          index_action "complete_#{name}", &block
        else
          index_action "complete_#{name}" do
            hobo_completions name, model, options
          end
        end
      end


      def web_method(web_name, options={}, &block)
        web_methods << web_name.to_sym
        method = options.delete(:method) || web_name
        got_block = block_given?
        define_method web_name do
          # Make sure we have a copy of the options - it is being mutated somewhere
          opts = {}.merge(options)
          self.this = find_instance(opts) unless opts[:no_find]
          raise Hobo::Model::PermissionDeniedError unless Hobo.can_call?(current_user, @this, method)
          if got_block
            instance_eval(&block)
          else
            @this.send(method)
          end

          hobo_ajax_response || render(:nothing => true) unless performed?
        end
      end


      def auto_actions(*args)
        options = args.extract_options!

        @auto_actions = case args.first
                          when :all        then available_auto_actions
                          when :write_only then available_auto_write_actions     + args.rest
                          when :read_only  then available_auto_read_actions      + args.rest
                          when :lifecycle  then available_auto_lifecycle_actions + args.rest
                          else args
                        end

        except = Array(options[:except])
        except_actions = except.map do |arg|
          case arg
            when :lifecycle   then available_auto_lifecycle_actions
            else arg
          end
        end

        @auto_actions -= except_actions.flatten

        def_auto_actions
      end


      def def_auto_actions
        self.class_eval do
          def index;   hobo_index   end if include_action?(:index)
          def show;    hobo_show    end if include_action?(:show)
          def new;     hobo_new     end if include_action?(:new)
          def create;  hobo_create  end if include_action?(:create)
          def edit;    hobo_show    end if include_action?(:edit)
          def update;  hobo_update  end if include_action?(:update)
          def destroy; hobo_destroy end if include_action?(:destroy)

          def completions; hobo_completions end if include_action?(:completions)

          def reorder; hobo_reorder end if include_action?(:reorder)
        end

        def_lifecycle_actions
      end


      def def_auto_action(name, &block)
        define_method name, &block if name.not_in?(instance_methods) && include_action?(name)
      end


      def def_lifecycle_actions
        if model.has_lifecycle?
          model::Lifecycle.creator_names.each do |creator|
            def_auto_action creator do
              creator_page_action creator
            end
            def_auto_action "do_#{creator}" do
              do_creator_action creator
            end
          end

          model::Lifecycle.transition_names.each do |transition|
            def_auto_action transition do
              transition_page_action transition
            end
            def_auto_action "do_#{transition}" do
              do_transition_action transition
            end
          end
        end
      end


      def show_action(*names, &block)
        options = names.extract_options!
        show_actions.concat(names)
        for name in names
          if block
            define_method(name, &block)
          else
            define_method(name) { hobo_show options.dup }
          end
        end
      end


      def index_action(*names, &block)
        options = names.extract_options!
        index_actions.concat(names)
        for name in names
          if block
            define_method(name, &block)
          else
            if scope = options.delete(:scope)
              define_method(name) { hobo_index scope, options.dup }
            else
              define_method(name) { hobo_index options.dup }
            end
          end
        end
      end
      
      
      def auto_actions_for(owner, actions)
        model.reverse_reflection(owner)._?.klass == model or 
          raise ArgumentError, "Invalid owner association '#{owner}' for #{model}"
        
        owner_actions[owner] ||= []
        Array(actions).each do |action|
          case action
          when :new
            define_method("new_for_#{owner}")    { hobo_new_for owner }
          when :index
            define_method("index_for_#{owner}")  { hobo_index_for owner }
          when :create
            define_method("create_for_#{owner}") { hobo_create_for owner }
          else
            raise ArgumentError, "Invalid owner action: #{action}"
          end
          owner_actions[owner] << action
        end
      end


      def include_action?(name)
        name.to_sym.in?(@auto_actions)
      end


      def available_auto_actions
        (available_auto_read_actions +
         available_auto_write_actions +
         FORM_ACTIONS +
         available_auto_lifecycle_actions).uniq
      end


      def available_auto_read_actions
        READ_ONLY_ACTIONS
      end


      def available_auto_write_actions
        if "position_column".in?(model.instance_methods)
          WRITE_ONLY_ACTIONS + [:reorder]
        else
          WRITE_ONLY_ACTIONS
        end
      end


      def available_auto_lifecycle_actions
        # For each creator/transition there are two possible
        # actions. e.g. for signup, 'signup' would be routed to
        # GET users/signup, and would show the form, while 'do_signup'
        # would be routed to POST /users/signup)
        if model.has_lifecycle?
          (model::Lifecycle.creator_names.map { |c| [c, "do_#{c}"] } +
           model::Lifecycle.transition_names.map { |t| [t, "do_#{t}"] }).flatten.*.to_sym
        else
          []
        end
      end

    end # of ClassMethods


    protected


    def parse_sort_param(*sort_fields)
      _, desc, field = *params[:sort]._?.match(/^(-)?([a-z_]+(?:\.[a-z_]+)?)$/)

      if field
        if field.in?(sort_fields.*.to_s)
          @sort_field = field
          @sort_direction = desc ? "desc" : "asc"

          [@sort_field, @sort_direction]
        end
      end
    end


    # --- Action implementation helpers --- #


    def find_instance(options={})
      model.user_find(current_user, params[:id], options)
    end


    def invalid?; !valid?; end


    def valid?; this.errors.empty?; end


    def re_render_form(default_action)
      if params[:page_path]
        controller, view = Controller.controller_and_view_for(params[:page_path])
        view = default_action if view == Dryml::EMPTY_PAGE
        @this = instance_variable_get("@#{controller.singularize}")
        render :template => "#{controller}/#{view}"
      else
        render :action => default_action
      end
    end


    def destination_after_submit(record=nil, destroyed=false)
      record ||= this

      after_submit = params[:after_submit]

      # The after_submit post parameter takes priority
      (after_submit == "stay-here" ? :back : after_submit) ||

        # Then try the record's show page
        (!destroyed && object_url(@this)) ||

        # Then the show page of the 'owning' object if there is one
        (@this.class.default_dependent_on && object_url(@this.send(@this.class.default_dependent_on))) ||

        # Last try - the index page for this model
        object_url(@this.class) ||

        # Give up
        home_page
    end
    
    
    def redirect_after_submit(*args)
      redirect_to destination_after_submit(*args)
    end
    

    def response_block(&b)
      if b
        if b.arity == 1
          respond_to {|wants| yield(wants) }
        else
          yield
        end
        performed?
      end
    end


    def request_requires_pagination?
      request.format.not_in?(DONT_PAGINATE_FORMATS)
    end


    def find_or_paginate(finder, options)
      options = options.reverse_merge(:paginate => request_requires_pagination?)
      do_pagination = options.delete(:paginate) && finder.respond_to?(:paginate)
      options[:order] = :default unless options[:order] || finder.send(:scope, :find)._?[:order]

      if do_pagination
        options.reverse_merge!(:page => params[:page] || 1)
        finder.paginate(options)
      else
        finder.all(options)
      end
    end
    
    
    def find_owner_and_association(owner_association)
      refl = model.reflections[owner_association]
      klass = refl.klass
      id = params["#{klass.name.underscore}_id"]
      owner = klass.find(id)
      instance_variable_set("@#{owner_association}", owner)
      [owner, owner.send(model.reverse_reflection(owner_association).name)]
    end


    # --- Action implementations --- #

    def hobo_index(*args, &b)
      options = args.extract_options!
      finder = args.first || model
      self.this = find_or_paginate(finder, options)
      response_block(&b)
    end
    
    
    def hobo_index_for(owner, *args, &b)
      options = args.extract_options!
      owner, association = find_owner_and_association(owner)
      finder = args.first || association
      self.this = find_or_paginate(finder, options)
      response_block(&b)
    end


    def hobo_show(*args, &b)
      options = args.extract_options!
      self.this = find_instance(options)
      response_block(&b)
    end


    def hobo_new(record=nil, &b)
      self.this = record || model.user_new!(current_user)
      response_block(&b)
    end
    
    
    def hobo_new_for(owner, record=nil, &b)
      owner, association = find_owner_and_association(owner)
      self.this = record || association.user_new(current_user)
      response_block(&b)
    end


    def hobo_create(*args, &b)
      options = args.extract_options!
      self.this = args.first || new_for_create
      this.user_save_changes(current_user, options[:attributes] || attribute_parameters || {})
      create_response(:new, &b)
    end
    
    
    def hobo_create_for(owner, *args, &b)
      options = args.extract_options!
      owner, association = find_owner_and_association(owner)
      self.this = args.first || association.new
      this.user_save_changes(current_user, options[:attributes] || attribute_parameters || {})
      create_response(:"new_for_#{owner}", &b)    
    end


    def attribute_parameters
      params[(this ? this.class : model).name.underscore]
    end


    def new_for_create
      type_param = subtype_for_create
      create_model = type_param ? type_param.constantize : model
      create_model.new
    end
    
    
    def subtype_for_create
      model.has_inheritance_column? && (t = params['type']) && t.in?(model.send(:subclasses).*.name) and
        t
    end
    


    def create_response(new_action, &b)
      flash[:notice] = "The #{@this.class.name.titleize.downcase} was created successfully" if !request.xhr? && valid?

      response_block(&b) or
        if valid?
          respond_to do |wants|
            wants.html { redirect_after_submit }
            wants.js   { hobo_ajax_response || render(:nothing => true) }
          end
        else
          respond_to do |wants|
            wants.html { re_render_form(new_action) }
            wants.js   { render(:status => 500,
                                :text => ("Couldn't create the #{this.class.name.titleize.downcase}.\n" +
                                          this.errors.full_messages.join("\n"))) }
          end
        end
    end


    def hobo_update(*args, &b)
      options = args.extract_options!

      self.this = args.first || find_instance
      changes = options[:attributes] || attribute_parameters or raise RuntimeError, "No update specified in params"
      this.user_save_changes(current_user, changes)

      # Ensure current_user isn't out of date
      @current_user = @this if @this == current_user

      in_place_edit_field = changes.keys.first if changes.size == 1 && params[:render]
      update_response(in_place_edit_field, &b)
    end


    def update_response(in_place_edit_field=nil, &b)
      flash[:notice] = "Changes to the #{@this.class.name.titleize.downcase} were saved" if !request.xhr? && valid?

      response_block(&b) or
        if valid?
          respond_to do |wants|
            wants.html do
              redirect_after_submit
            end
            wants.js do
              if in_place_edit_field
                # Decreasingly hacky support for the scriptaculous in-place-editor
                new_val = call_dryml_tag("view", :field => in_place_edit_field, :no_wrapper => true)
                hobo_ajax_response(this, :new_field_value => new_val)
              else
                hobo_ajax_response(this)
              end

              # Maybe no ajax requests were made
              render :nothing => true unless performed?
            end
          end
        else
          respond_to do |wants|
            wants.html { re_render_form(:edit) }
            wants.js { render(:status => 500,
                              :text => ("There was a problem with that change.\n" +
                                        @this.errors.full_messages.join("\n"))) }
          end
        end
    end


    def hobo_destroy(*args, &b)
      options = args.extract_options!
      self.this = args.first || find_instance
      this.user_destroy(current_user)
      flash[:notice] = "The #{model.name.titleize.downcase} was deleted" unless request.xhr?
      destroy_response(&b)
    end


    def destroy_response(&b)
      response_block(&b) or
        respond_to do |wants|
          wants.html { redirect_after_submit(this, true) }
          wants.js   { hobo_ajax_response || render(:nothing => true) }
        end
    end


    # --- Lifecycle Actions --- #

    def do_creator_action(name, &b)
      @creator = model::Lifecycle.creators[name.to_s]
      self.this = @creator.run!(current_user, attribute_parameters)
      response_block(&b) or
        if valid?
          redirect_after_submit
        else
          re_render_form(name)
        end
    end


    def creator_page_action(name)
      self.this = model.new
      @creator = model::Lifecycle.creators[name.to_s] or raise ArgumentError, "No such creator in lifecycle: #{name}"
    end


    def prepare_for_transition(name, options={})
      self.this = find_instance
      this.exempt_from_edit_checks = true
      this.lifecycle.provided_key = params[:key]
      @transition = this.lifecycle.find_transition(name, current_user)
    end


    def do_transition_action(name, *args, &b)
      prepare_for_transition(name)
      @transition.run!(this, current_user, attribute_parameters)
      response_block(&b) or
        if valid?
          redirect_after_submit
        else
          re_render_form(name)
        end
    end


    def transition_page_action(name, *args)
      options = args.extract_options!
      prepare_for_transition(name, options)
    end

    # --- Miscelaneous Actions --- #

    def hobo_completions(attribute, finder, options={})
      options = options.reverse_merge(:limit => 10, :param => :query)
      finder = finder.limit(options[:limit]) unless finder.send(:scope, :find, :limit)
      finder = finder.send("#{attribute}_contains", params[options[:param]])
      items = finder.find(:all)
      render :text => "<ul>\n" + items.map {|i| "<li>#{i.send(attribute)}</li>\n"}.join + "</ul>"
    end


    def hobo_reorder
      ordering = params["#{model.name.underscore}_ordering"]
      if ordering
        ordering.each_with_index do |id, position|
          model.user_update(current_user, id, :position => position+1)
        end
        hobo_ajax_response || render(:nothing => true)
      else
        render :nothing => true
      end
    end



    # --- Response helpers --- #

    def permission_denied(error)
      self.this = nil # Otherwise this gets sent user_view
      if :permission_denied.in?(self.class.superclass.instance_methods)
        super
      else
        respond_to do |wants|
          wants.html do
            if render_tag("permission-denied-page", { }, :status => 403)
              # job done
            else
              render :text => "Permission Denied", :status => 403
            end
          end
          wants.js do
            render :text => "Permission Denied", :status => 403
          end
        end
      end
    end


    def not_found(error)
      if :not_found_response.in?(self.class.superclass.instance_methods)
        super
      elsif render_tag("not-found-page", {}, :status => 404)
        # cool
      else
        render(:text => "The page you requested cannot be found.", :status => 404)
      end
    end


    def this
      @this ||= (instance_variable_get("@#{model.name.underscore}") ||
                 instance_variable_get("@#{model.name.underscore.pluralize}"))
    end


    def this=(object)
      ivar = if object.is_a?(Array)
               (object.try.member_class || model).name.underscore.pluralize
             else
               object.class.name.underscore
             end
      @this = instance_variable_set("@#{ivar}", object)
    end


    def dryml_context
      this
    end


    def render_with_hobo_model(*args, &block)
      options = args.extract_options!
      self.this = options[:object] if options[:object]
      this.user_view(current_user) if this && this.respond_to?(:user_view)
      render_without_hobo_model(*args + [options], &block)
    end

    # --- filters --- #

    def set_no_cache_headers
      headers["Pragma"] = "no-cache"
      #headers["Cache-Control"] = ["must-revalidate", "no-cache", "no-store"]
      #headers["Cache-Control"] = "no-cache"
      headers["Cache-Control"] = "no-store"
      headers["Expires"] ='0'
    end

    # --- end filters --- #

    public

    def model
      self.class.model
    end

  end

end
