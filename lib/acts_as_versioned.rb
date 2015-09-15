# Copyright (c) 2005 Rick Olson
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
require 'active_support/concern'

module ActiveRecord #:nodoc:
  module Acts #:nodoc:
    # Specify this act if you want to save a copy of the row in a versioned table.  This assumes there is a 
    # versioned table ready and that your model has a version field.  This works with optimistic locking if the lock_version
    # column is present as well.
    #
    # The class for the versioned model is derived the first time it is seen. Therefore, if you change your database schema you have to restart
    # your container for the changes to be reflected. In development mode this usually means restarting WEBrick.
    #
    #   class Page < ActiveRecord::Base
    #     # assumes pages_versions table
    #     acts_as_versioned
    #   end
    #
    # Example:
    #
    #   page = Page.create(:title => 'hello world!')
    #   page.version       # => 1
    #
    #   page.title = 'hello world'
    #   page.save
    #   page.version       # => 2
    #   page.versions.size # => 2
    #
    #   page.revert_to(1)  # using version number
    #   page.title         # => 'hello world!'
    #
    #   page.revert_to(page.versions.last) # using versioned instance
    #   page.title         # => 'hello world'
    #
    #   page.versions.earliest # efficient query to find the first version
    #   page.versions.latest   # efficient query to find the most recently created version
    #
    #
    # Simple Queries to page between versions
    #
    #   page.versions.before(version) 
    #   page.versions.after(version)
    #
    # Access the previous/next versions from the versioned model itself
    #
    #   version = page.versions.latest
    #   version.previous # go back one version
    #   version.next     # go forward one version
    #
    # See ActiveRecord::Acts::Versioned::ClassMethods#acts_as_versioned for configuration options
    module Versioned
      VERSION   = "0.6.0"
      CALLBACKS = [:set_new_version, :save_version, :save_version?]

      # == Configuration options
      #
      # * <tt>class_name</tt> - versioned model class name (default: PageVersion in the above example)
      # * <tt>table_name</tt> - versioned model table name (default: page_versions in the above example)
      # * <tt>foreign_key</tt> - foreign key used to relate the versioned model to the original model (default: page_id in the above example)
      # * <tt>inheritance_column</tt> - name of the column to save the model's inheritance_column value for STI.  (default: versioned_type)
      # * <tt>version_column</tt> - name of the column in the model that keeps the version number (default: version)
      # * <tt>sequence_name</tt> - name of the custom sequence to be used by the versioned model.
      # * <tt>limit</tt> - number of revisions to keep, defaults to unlimited
      # * <tt>if</tt> - symbol of method to check before saving a new version.  If this method returns false, a new version is not saved.
      #   For finer control, pass either a Proc or modify Model#version_condition_met?
      #
      #     acts_as_versioned :if => Proc.new { |auction| !auction.expired? }
      #
      #   or...
      #
      #     class Auction
      #       def version_condition_met? # totally bypasses the <tt>:if</tt> option
      #         !expired?
      #       end
      #     end
      #
      # * <tt>if_changed</tt> - Simple way of specifying attributes that are required to be changed before saving a model.  This takes
      #   either a symbol or array of symbols.
      #
      # * <tt>extend</tt> - Lets you specify a module to be mixed in both the original and versioned models.  You can also just pass a block
      #   to create an anonymous mixin:
      #
      #     class Auction
      #       acts_as_versioned do
      #         def started?
      #           !started_at.nil?
      #         end
      #       end
      #     end
      #
      #   or...
      #
      #     module AuctionExtension
      #       def started?
      #         !started_at.nil?
      #       end
      #     end
      #     class Auction
      #       acts_as_versioned :extend => AuctionExtension
      #     end
      #
      #  Example code:
      #
      #    @auction = Auction.find(1)
      #    @auction.started?
      #    @auction.versions.first.started?
      #
      # == Database Schema
      #
      # The model that you're versioning needs to have a 'version' attribute. The model is versioned
      # into a table called #{model}_versions where the model name is singlular. The _versions table should
      # contain all the fields you want versioned, the same version column, and a #{model}_id foreign key field.
      #
      # A lock_version field is also accepted if your model uses Optimistic Locking.  If your table uses Single Table inheritance,
      # then that field is reflected in the versioned model as 'versioned_type' by default.
      #
      # Acts_as_versioned comes prepared with the ActiveRecord::Acts::Versioned::ActMethods::ClassMethods#create_versioned_table
      # method, perfect for a migration.  It will also create the version column if the main model does not already have it.
      #
      #   class AddVersions < ActiveRecord::Migration
      #     def self.up
      #       # create_versioned_table takes the same options hash
      #       # that create_table does
      #       Post.create_versioned_table
      #     end
      #
      #     def self.down
      #       Post.drop_versioned_table
      #     end
      #   end
      #
      # == Changing What Fields Are Versioned
      #
      # By default, acts_as_versioned will version all but these fields:
      #
      #   [self.primary_key, inheritance_column, 'version', 'lock_version', versioned_inheritance_column]
      #
      # You can add or change those by modifying #non_versioned_columns.  Note that this takes strings and not symbols.
      #
      #   class Post < ActiveRecord::Base
      #     acts_as_versioned
      #     self.non_versioned_columns << 'comments_count'
      #   end
      #
      def acts_as_versioned(options = {}, &extension)
        # don't allow multiple calls
        return if self.included_modules.include?(ActiveRecord::Acts::Versioned::Behaviors)

        cattr_accessor :versioned_class_name, :versioned_foreign_key, :versioned_table_name, :versioned_inheritance_column, 
          :version_column, :max_version_limit, :track_altered_attributes, :version_condition, :version_sequence_name, :non_versioned_columns,
          :version_association_options, :version_if_changed, :version_unless_changed

        self.versioned_class_name         = options[:class_name] || "Version"
        self.versioned_foreign_key        = options[:foreign_key] || self.base_class.to_s.foreign_key
        self.versioned_table_name         = options[:table_name] || "#{table_name_prefix}#{base_class.name.demodulize.underscore}_versions#{table_name_suffix}"
        self.versioned_inheritance_column = options[:inheritance_column] || "versioned_#{inheritance_column}"
        self.version_column               = options[:version_column] || 'version'
        self.version_sequence_name        = options[:sequence_name]
        self.max_version_limit            = options[:limit].to_i
        self.version_condition            = options[:if] || true
        self.non_versioned_columns        = [self.primary_key, inheritance_column, self.version_column, 'lock_version', versioned_inheritance_column] + options[:non_versioned_columns].to_a.map(&:to_s)
        self.version_if_changed           = [] #This needs to be initialized, but is set below
        self.version_unless_changed       = self.non_versioned_columns 
        self.version_association_options  = {
                                              :class_name  => "#{self.to_s}::#{versioned_class_name}",
                                              :foreign_key => versioned_foreign_key
                                            }.merge(options[:association_options] || {})

        if block_given?
          extension_module_name = "#{versioned_class_name}Extension"
          silence_warnings do
            self.const_set(extension_module_name, Module.new(&extension))
          end

          options[:extend] = self.const_get(extension_module_name)
        end

        unless options[:if_changed].nil?
          self.track_altered_attributes = true
          options[:if_changed] = [options[:if_changed]] unless options[:if_changed].is_a?(Array)
          self.version_if_changed = options[:if_changed].map(&:to_s)
        end

        include options[:extend] if options[:extend].is_a?(Module)

        include ActiveRecord::Acts::Versioned::Behaviors

        #
        # Create the dynamic versioned model
        #
        const_set(versioned_class_name, Class.new(ActiveRecord::Base)).class_eval do
          def self.reloadable?;
            false;
          end

          # find first version before the given version
          def self.before(version)
            where(["#{original_class.versioned_foreign_key} = ? and version < ?", version.send(original_class.versioned_foreign_key), version.version]).
                    order('version DESC').
                    first
          end

          # find first version after the given version.
          def self.after(version)
            where(["#{original_class.versioned_foreign_key} = ? and version > ?", version.send(original_class.versioned_foreign_key), version.version]).
                    order('version ASC').
                    first
          end

          # finds earliest version of this record
          def self.earliest
            order("#{original_class.version_column}").first
          end

          # find latest version of this record
          def self.latest
            order("#{original_class.version_column} desc").first
          end

          def previous
            self.class.before(self)
          end

          def next
            self.class.after(self)
          end

          def versions_count
            page.version
          end
          
          def is_versioned_class?
            true
          end
        end
        
        reflections.each do |name, reflection|
          next if reflection.macro != :belongs_to || reflection.options[:polymorphic]
           versioned_class.send(reflection.macro, *[name.to_sym, ->{reflection.scope ? reflection.scope.readonly : readonly}, reflection.options])
        end

        versioned_class.cattr_accessor :original_class
        versioned_class.original_class = self
        versioned_class.table_name = versioned_table_name
        versioned_class.belongs_to self.to_s.demodulize.underscore.to_sym,
                                   :class_name  => "::#{self.to_s}",
                                   :foreign_key => versioned_foreign_key
        versioned_class.send :include, options[:extend] if options[:extend].is_a?(Module)
        versioned_class.sequence_name= version_sequence_name if version_sequence_name
      end

      module Behaviors
        extend ActiveSupport::Concern

        included do
          has_many :versions, self.version_association_options

          before_save :set_new_version
          after_save :save_version
          after_save :clear_old_versions
          
        end
        
        def versioned_associations
          self.class.versioned_associations
        end

        # Saves a version of the model in the versioned table.  This is called in the after_save callback by default
        def save_version
          if @saving_version
            @saving_version = nil
            rev = self.class.versioned_class.new
            clone_versioned_model(self, rev)
            rev.send("#{self.class.version_column}=", send(self.class.version_column))
            rev.send("#{self.class.versioned_foreign_key}=", id)
            
            self.class.versioned_association_reflections.reject{|n, x| x.macro != :belongs_to}.each do |name, reflection|
              if assoc = self.send(name.to_sym)
                next unless assoc.respond_to?(:current_version)
                if reflection.options[:polymorphic]
                  if assoc.current_version.nil? == false
                    rev.send("#{self.class.versioned_association_foreign_key(reflection.foreign_key)}=", assoc.current_version.id)
                    rev.send("#{self.class.versioned_association_foreign_key(reflection.foreign_type)}=", assoc.class.versioned_class.to_s)
                  else
                    rev.send("#{self.class.versioned_association_foreign_key(reflection.foreign_key)}=", nil)
                    rev.send("#{self.class.versioned_association_foreign_key(reflection.foreign_type)}=", nil)
                  end
                else
                  if assoc.current_version.nil? == false
                    rev.send("#{self.class.versioned_association_foreign_key(reflection.foreign_key)}=", assoc.current_version.id)
                  else
                    rev.send("#{self.class.versioned_association_foreign_key(reflection.foreign_key)}=", nil)
                  end
                end
              end
            end
            
            rev.save
          end
        end
        
        def current_version
          fetch_version(version)
        end
        
        def current_version?
          current_version.version == version
        end

        # Clears old revisions if a limit is set with the :limit option in <tt>acts_as_versioned</tt>.
        # Override this method to set your own criteria for clearing old versions.
        def clear_old_versions
          return if self.class.max_version_limit == 0
          excess_baggage = send(self.class.version_column).to_i - self.class.max_version_limit
          if excess_baggage > 0
            self.class.versioned_class.delete_all ["#{self.class.version_column} <= ? and #{self.class.versioned_foreign_key} = ?", excess_baggage, id]
          end
        end

        # Reverts a model to a given version.  Takes either a version number or an instance of the versioned model
        def revert_to(version)
          if version.is_a?(self.class.versioned_class)
            return false unless version.send(self.class.versioned_foreign_key) == id and !version.new_record?
          else
            return false unless version = versions.where(self.class.version_column => version).first
          end
          self.clone_versioned_model(version, self)
          send("#{self.class.version_column}=", version.send(self.class.version_column))
          true
        end
        
        def fetch_version(version_to_fetch)
          versions.where(self.class.version_column.to_sym => version_to_fetch).first
        end

        # Reverts a model to a given version and saves the model.
        # Takes either a version number or an instance of the versioned model
        def revert_to!(version)
          revert_to(version) ? save_without_revision : false
        end

        # Temporarily turns off Optimistic Locking while saving.  Used when reverting so that a new version is not created.
        def save_without_revision
          save_without_revision!
          true
        rescue
          false
        end

        def save_without_revision!
          without_locking do
            without_revision do
              save!
            end
          end
        end
                
        def altered?
          if track_altered_attributes 
            (version_if_changed & changed).any? 
          else
            (changed - version_unless_changed).any?
          end
        end
        

        # Clones a model.  Used when saving a new version or reverting a model's version.
        def clone_versioned_model(orig_model, new_model)
          self.class.versioned_columns.each do |col|
            next unless orig_model.has_attribute?(col.name)
            new_model.send("#{col.name.to_sym}=", orig_model.send(col.name))
          end
          
          if orig_model.is_a?(self.class.versioned_class) && new_model.has_attribute?(new_model.class.inheritance_column)
            new_model[new_model.class.inheritance_column] = orig_model[self.class.versioned_inheritance_column]
          elsif new_model.is_a?(self.class.versioned_class) && new_model.has_attribute?(self.class.versioned_inheritance_column)
            new_model[self.class.versioned_inheritance_column] = orig_model[orig_model.class.inheritance_column]
          end
        end
          
        def define_method(object, method)
          return if object.methods.include? method
          metaclass = class << object; self; end
          metaclass.send :attr_accessor, method
        end

        # Checks whether a new version shall be saved or not.  Calls <tt>version_condition_met?</tt> and <tt>changed?</tt>.
        def save_version?
          version_condition_met? && altered?
        end

        # Checks condition set in the :if option to check whether a revision should be created or not.  Override this for
        # custom version condition checking.
        def version_condition_met?
          case
            when version_condition.is_a?(Symbol)
              send(version_condition)
            when version_condition.respond_to?(:call) && (version_condition.arity == 1 || version_condition.arity == -1)
              version_condition.call(self)
            else
              version_condition
          end
        end

        # Executes the block with the versioning callbacks disabled.
        #
        #   @foo.without_revision do
        #     @foo.save
        #   end
        #
        def without_revision(&block)
          self.class.without_revision(&block)
        end

        # Turns off optimistic locking for the duration of the block
        #
        #   @foo.without_locking do
        #     @foo.save
        #   end
        #
        def without_locking(&block)
          self.class.without_locking(&block)
        end

        # Accepts a column to pull the change history for and an options hash.
        # The options has takes a :format option to select the output format, options include
        # :raw, :objects, and :human.  Defaults to :human
        def change_history_for(field, opts = {:format => :human})
          opts.assert_valid_keys(:format)
          field = field.to_s
          changes = connection.select_all("            
            select version, changed_field as 'to', previous as 'from', updated_at as 'when', updated_by as 'who'
            FROM (
              select 
              @r := @r + (NOT @prev <=> changed_field) as `grouping`,
              @prev as 'previous',
              @prev := IF(@prev <=> changed_field, @prev, changed_field) ,
              changed_field,
              #{version_column} as `version`,
              updated_at, updated_by
            FROM  
              (SELECT @prev := NULL, @current := NULL, @r := 0) vars,
              ( select #{version_column}, #{field} as `changed_field`, updated_at, updated_by 
                from #{versioned_table_name} 
                WHERE #{versioned_foreign_key} = #{self.id} ORDER BY version asc) versions

            ) q
            GROUP BY grouping
          ")
          
          if opts[:format] == :objects || opts[:format] == :human
            # Object and Human formats get mixed in here since the objects are a precursor to the human formats
            changes.each{|x| x["when"] = Time.zone.parse(x["when"]).localtime }
            changes.each{|x| x["when"] = x["when"].to_s(:long)} if opts[:format] == :human
            
            if field.ends_with?("_id")
              accessor = field.gsub("_id",'').to_sym
              if (reflection = self.class.versioned_class.reflect_on_association(accessor)) && reflection.association_foreign_key == field
                changes.each_index do |i|
                  ["from", "to"].each do |versioned_data|
                    related_record = reflection.klass.find_by_id(changes[i][versioned_data])
                    if related_record.present? 
                      if opts[:format] == :human 
                        if (accessor = [:name, :title, :code].detect{|display| related_record.respond_to?(display)})
                          changes[i][versioned_data] = related_record.send(accessor)
                        end
                      else
                        changes[i][versioned_data] = related_record
                      end
                    end          
                  end
                end
              end
            elsif field.ends_with?("_at")
              ["from", "to"].each do |versioned_data|
                changes.each{|x| x[versioned_data] = Time.zone.parse(x[versioned_data]).localtime if x[versioned_data].present?}
                changes.each{|x| x[versioned_data] = x[versioned_data].to_s(:long) if x[versioned_data].present?} if opts[:format] == :human
              end
            end
            
          end
          
          changes

        end
        
        
        def empty_callback()
        end

        #:nodoc:

        protected
        # sets the new version before saving, unless you're using optimistic locking.  In that case, let it take care of the version.
        def set_new_version
          @saving_version = new_record? || save_version?
          self.send("#{self.class.version_column}=", next_version) if new_record? || (!locking_enabled? && save_version?)
        end

        # Gets the next available version for the current record, or 1 for a new record
        def next_version
          (new_record? ? 0 : versions.calculate(:maximum, version_column).to_i) + 1
        end


        module ClassMethods
          
          
          # Returns an array of columns that are versioned.  See non_versioned_columns
          def versioned_columns
            @versioned_columns ||= columns.select { |c| !non_versioned_columns.include?(c.name) }
          end

          # Returns an instance of the dynamic versioned model
          def versioned_class
            const_get versioned_class_name
          end
          
          def versioned_associations
            versioned_association_reflections.keys.collect(&:to_sym)
          end
          
          # List reflections that are also versioned
          def versioned_association_reflections
            reflections.reject { |name, reflection| 
              if reflection.options[:polymorphic] || (reflection.class_name == superclass.to_s && superclass != Object)
                false
              else
                reflection.klass.respond_to?(:versioned_class) == false
              end
            }
          end
          
          def versioned_association_foreign_key(existing_key)
            "versioned_#{existing_key}"
          end

          # Rake migration task to create the versioned table using options passed to acts_as_versioned
          def create_versioned_table(create_table_options = {})
            # create version column in main table if it does not exist
            if !self.content_columns.find { |c| [version_column.to_s, 'lock_version'].include? c.name }
              self.connection.add_column table_name, version_column, :integer
              self.reset_column_information
            end

            return if connection.table_exists?(versioned_table_name)

            self.connection.create_table(versioned_table_name, create_table_options) do |t|
              t.column versioned_foreign_key, :integer
              t.column version_column, :integer
            end

            self.versioned_columns.each do |col|
              self.connection.add_column versioned_table_name, col.name, col.type,
                                         :limit     => col.limit,
                                         :default   => col.default,
                                         :scale     => col.scale,
                                         :precision => col.precision
            end

            if type_col = self.columns_hash[inheritance_column]
              self.connection.add_column versioned_table_name, versioned_inheritance_column, type_col.type,
                                         :limit     => type_col.limit,
                                         :default   => type_col.default,
                                         :scale     => type_col.scale,
                                         :precision => type_col.precision
            end
            
            # Add columns to store the versioned types
            versioned_association_reflections.values.reject{|x| x.macro != :belongs_to}.each do |reflection|
              if reflection.options[:polymorphic]
                self.connection.add_column versioned_table_name, versioned_association_foreign_key(reflection.foreign_key), :integer
                self.connection.add_column versioned_table_name, versioned_association_foreign_key(reflection.foreign_type), :string
              else
                self.connection.add_column versioned_table_name, versioned_association_foreign_key(reflection.foreign_key), :integer
              end
            end

            self.connection.add_index versioned_table_name, versioned_foreign_key
          end
          
          # Rake migration task to match the versioned table.  Will add columns to the versioned table,
          # but will not remove columns.  Any columns removed from the source but not the versioned 
          # table will be noted in the console output.
          def update_versioned_table(create_table_options = {})
            
            self.reset_column_information
            self.versioned_class.reset_column_information
            @versioned_columns = nil #A hackish re-set of versioned columns
            
            create_versioned_table(create_table_options) unless connection.table_exists?(versioned_table_name)
            
            #Add newly created columns
            self.versioned_columns.each do |col| 
              unless self.versioned_class.columns.detect{|c| c.name == col.name}
                self.versioned_class.connection.add_column versioned_table_name, col.name, col.type, 
                  :limit     => col.limit, 
                  :default   => col.default,
                  :scale     => col.scale,
                  :precision => col.precision
              end
            end
            
            #I don't trust this enough to not clobber columns we need, so it puts out a list
            self.versioned_class.columns.each do |col|
              unless self.versioned_columns.detect{|c| c.name == col.name}
                if !["id", version_column, versioned_foreign_key, version_column].include?(col.name) && !col.name.starts_with?("versioned_")
                  puts "***  #{col.name} is in #{versioned_table_name} but no longer in the source table.  Perhaps you want a migration to remove it?"
                  puts "***  remove_column :#{versioned_table_name}, :#{col.name}"
                end
              end
            end
            
            
            #Check the associated models
            versioned_column_names = self.versioned_class.columns.collect{|c| c.name}
            versioned_association_reflections.values.reject{|x| x.macro != :belongs_to}.each do |reflection|
              if reflection.options[:polymorphic]
                unless versioned_column_names.include?(versioned_association_foreign_key(reflection.foreign_key))
                  self.connection.add_column versioned_table_name, versioned_association_foreign_key(reflection.foreign_key), :integer
                end
                unless versioned_column_names.include?(versioned_association_foreign_key(reflection.foreign_type))
                  self.connection.add_column versioned_table_name, versioned_association_foreign_key(reflection.foreign_type), :string
                end
              else
                cname = versioned_association_foreign_key(reflection.foreign_key)
                unless versioned_column_names.include?(cname)
                  self.connection.add_column versioned_table_name, cname, :integer
                end
              end
            end

            
          end

          # Rake migration task to drop the versioned table
          def drop_versioned_table
            self.connection.drop_table versioned_table_name
          end

          # Executes the block with the versioning callbacks disabled.
          #
          #   Foo.without_revision do
          #     @foo.save
          #   end
          #
          def without_revision(&block)
            class_eval do
              CALLBACKS.each do |attr_name|
                alias_method "orig_#{attr_name}".to_sym, attr_name
                alias_method attr_name, :empty_callback
              end
            end
            block.call
          ensure
            class_eval do
              CALLBACKS.each do |attr_name|
                alias_method attr_name, "orig_#{attr_name}".to_sym
              end
            end
          end

          # Turns off optimistic locking for the duration of the block
          #
          #   Foo.without_locking do
          #     @foo.save
          #   end
          #
          def without_locking(&block)
            current = ActiveRecord::Base.lock_optimistically
            ActiveRecord::Base.lock_optimistically = false if current
            begin
              block.call
            ensure
              ActiveRecord::Base.lock_optimistically = true if current
            end
          end
        end
      end
    end
  end
end

ActiveRecord::Base.extend ActiveRecord::Acts::Versioned
