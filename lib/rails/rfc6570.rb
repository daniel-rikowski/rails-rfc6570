# frozen_string_literal: true

require 'rails/rfc6570/version'

module ActionDispatch
  module Journey
    module Visitors
      class RFC6570 < Visitor # rubocop:disable ClassLength
        DISPATCH_CACHE = {} # rubocop:disable MutableConstant

        def initialize(opts = {})
          super()

          @opts        = opts
          @stack       = []
          @group_depth = 0
        end

        def ignore
          @opts.fetch(:ignore) { %w[format] }
        end

        def route
          @route ||= @opts[:route]
        end

        # rubocop:disable AbcSize
        def accept(node)
          str = visit(node)

          if @opts.fetch(:params, true) && route
            controller = route.defaults[:controller].to_s
            action     = route.defaults[:action].to_s

            if controller.present? && action.present?
              params = Rails::RFC6570.params_for(controller, action)
              str += '{?' + params.join(',') + '}' if params&.any?
            end
          end

          str
        end
        # rubocop:enable all

        def visit(node)
          @stack.unshift node.type
          send DISPATCH_CACHE.fetch(node.type), node
        ensure
          @stack.shift
        end

        def symbol_name(node)
          name = node.to_s.tr '*:', ''

          if ignore.include?(name)
            nil
          else
            name
          end
        end

        def placeholder(node, prefix = nil, suffix = nil, pretext = nil)
          name = symbol_name node
          if name
            "#{pretext}{#{prefix}#{name}#{suffix}}"
          else
            ''
          end
        end

        # rubocop:disable AbcSize
        # rubocop:disable CyclomaticComplexity
        # rubocop:disable MethodLength
        # rubocop:disable PerceivedComplexity
        def binary(node)
          case [node.left.type, node.right.type]
            when %i[DOT SYMBOL]
              if @stack[0..1] == %i[CAT GROUP]
                placeholder node.right, '.'
              else
                placeholder(node.right, nil, nil, '.')
              end
            when %i[SLASH SYMBOL]
              if @stack[0..1] == %i[CAT GROUP]
                placeholder(node.right, '/')
              else
                placeholder(node.right, nil, nil, '/')
              end
            when %i[SLASH STAR]
              placeholder node.right, '/', '*'
            when %i[SLASH CAT]
              if node.right.left.type == :STAR
                placeholder(node.right.left, '/', '*') +
                  visit(node.right.right)
              else
                [visit(node.left), visit(node.right)].join
              end
            when %i[CAT STAR]
              visit(node.left).to_s.gsub(%r{/+$}, '') +
                placeholder(node.right, '/', '*')
            else
              [visit(node.left), visit(node.right)].join
          end
        end
        # rubocop:enable all

        def terminal(node)
          node.left
        end

        def nary(node)
          node.children.each {|c| visit(c) }
        end

        def unary(node)
          visit(node.left)
        end

        # rubocop:disable MethodName
        def visit_CAT(node)
          binary(node)
        end

        def visit_LITERAL(node)
          terminal(node)
        end

        def visit_SLASH(node)
          terminal(node)
        end

        def visit_DOT(node)
          terminal(node)
        end

        def visit_SYMBOL(node)
          placeholder(node)
        end

        def visit_OR(node)
          nary(node)
        end

        def visit_STAR(node)
          unary(node)
        end

        def visit_GROUP(node)
          raise 'Cannot transform nested groups.' if @group_depth >= 1

          @group_depth += 1
          visit node.left
        ensure
          @group_depth -= 1
        end
        # rubocop:enable MethodName

        instance_methods(true).each do |meth|
          next unless meth =~ /^visit_(.*)$/
          DISPATCH_CACHE[Regexp.last_match(1).to_sym] = meth
        end
      end
    end
  end
end

module Rails
  module RFC6570
    if defined?(::Rails::Railtie)
      class Railtie < ::Rails::Railtie # :nodoc:
        initializer 'rails-rfc6570', group: :all do |_app|
          require 'rails/rfc6570/patches'
          require 'action_dispatch/journey'

          MAJOR = Rails::VERSION::MAJOR
          MINOR = Rails::VERSION::MINOR

          ::ActionDispatch::Routing::RouteSet.send :include,
            Rails::RFC6570::Extensions::RouteSet

          ::ActionDispatch::Routing::RouteSet::NamedRouteCollection.send \
            :prepend, Rails::RFC6570::Extensions::NamedRouteCollection

          ::ActionDispatch::Journey::Route.send :include,
            Rails::RFC6570::Extensions::JourneyRoute

          ::ActionDispatch::Journey::Nodes::Node.send :include,
            Rails::RFC6570::Extensions::JourneyNode

          ::ActiveSupport.on_load(:action_controller) do
            include Rails::RFC6570::Helper
            extend Rails::RFC6570::ControllerExtension
          end
        end
      end
    end

    module Extensions
      module RouteSet
        def to_rfc6570(opts = {})
          routes.map {|r| r.to_rfc6570(opts) }
        end
      end

      module NamedRouteCollection
        def to_rfc6570(opts = {})
          Hash[routes.map {|n, r| [n, r.to_rfc6570(opts)] }]
        end

        # rubocop:disable AbcSize
        # rubocop:disable MethodLength
        def define_rfc6570_helpers(name, route, mod, set)
          rfc6570_name      = :"#{name}_rfc6570"
          rfc6570_url_name  = :"#{name}_url_rfc6570"
          rfc6570_path_name = :"#{name}_path_rfc6570"

          [rfc6570_name, rfc6570_url_name, rfc6570_path_name].each do |helper|
            mod.send :undef_method, helper if mod.respond_to? helper
          end

          mod.module_eval do
            define_method(rfc6570_name) do |opts = {}|
              ::Rails::RFC6570.build_url_template(self, route, opts)
            end

            define_method(rfc6570_url_name) do |opts = {}|
              send rfc6570_name, opts.merge(path_only: false)
            end

            define_method(rfc6570_path_name) do |opts = {}|
              send rfc6570_name, opts.merge(path_only: true)
            end
          end

          set << rfc6570_name
          set << rfc6570_url_name
          set << rfc6570_path_name
        end
        # rubocop:enable all

        def add(name, route)
          super
          define_rfc6570_helpers name, route, @url_helpers_module, @url_helpers
        end

        alias []= add
      end

      module JourneyRoute
        def to_rfc6570(opts = {})
          path.spec.to_rfc6570 opts.merge(route: self)
        end
      end

      module JourneyNode
        def to_rfc6570(opts = {})
          ::Addressable::Template.new \
            ::ActionDispatch::Journey::Visitors::RFC6570.new(opts).accept(self)
        end
      end
    end

    module Helper
      def rfc6570_routes(opts = {})
        routes = {}
        Rails.application.routes.named_routes.names.each do |key|
          routes[key] = rfc6570_route(key, opts)
        end

        routes
      end

      def rfc6570_route(name, opts = {})
        route = Rails.application.routes.named_routes[name]
        raise KeyError.new "No named routed for `#{name}'." unless route

        ::Rails::RFC6570.build_url_template(self, route, opts)
      end
    end

    module ControllerExtension
      def rfc6570_defs
        @__rfc6570_defs ||= {}
      end

      def rfc6570_params(defs)
        rfc6570_defs.merge! defs
      end

      def rfc6570_params_for(defs)
        rfc6570_defs[defs]
      end
    end

    # rubocop:disable MethodLength
    def build_url_template(t, route, options)
      template = route.to_rfc6570(options)

      if options.fetch(:path_only, false)
        template
      else
        options = t.url_options.merge(options)
        options[:path] = template.pattern

        original_script_name = options.delete(:original_script_name)

        if original_script_name
          options[:script_name] = original_script_name + options[:script_name]
        end

        url = ActionDispatch::Http::URL.url_for(options)

        ::Addressable::Template.new(url)
      end
    end
    # rubocop:enable all

    def params_for(controller, action)
      ctr = "#{controller.camelize}Controller".constantize
      ctr.rfc6570_defs[action.to_sym] if ctr.respond_to?(:rfc6570_defs)
    rescue NameError
      nil
    end

    extend self # rubocop:disable ModuleFunction
  end
end
