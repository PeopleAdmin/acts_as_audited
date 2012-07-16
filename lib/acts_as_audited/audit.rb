require 'set'

# Audit saves the changes to ActiveRecord models.  It has the following attributes:
#
# * <tt>auditable</tt>: the ActiveRecord model that was changed
# * <tt>user</tt>: the user that performed the change; a string or an ActiveRecord model
# * <tt>action</tt>: one of create, update, or delete
# * <tt>audited_changes</tt>: a serialized hash of all the changes
# * <tt>comment</tt>: a comment set with the audit
# * <tt>created_at</tt>: Time that the change was performed
#
class Audit < ActiveRecord::Base

  DEFAULT_USER_NAME = "System"

  attr_accessor :display_map

  belongs_to :auditable, :polymorphic => true
  belongs_to :user, :polymorphic => true
  belongs_to :associated, :polymorphic => true

  before_create :set_audit_version_number, :set_audit_user
  before_save :fix_timezone

  serialize :audited_changes

  cattr_accessor :audited_class_names
  self.audited_class_names = Set.new

  # Order by ver
  default_scope order(:audit_version)
  scope :descending, reorder("audit_version DESC")

  # PeopleAdmin Scopes
  scope :my_deleted_associations, lambda { |object|
    {:conditions => ["audits.action = 'destroy' AND audits.audited_changes LIKE ?", '%'+ "#{object.class.to_s.foreign_key}: \n- \n- #{object.id}\n" +'%']}
  }

  scope :my_deleted_association, lambda { |object, class_name|
    {:conditions => ["audits.action = 'destroy' AND audits.auditable_type = ? AND audits.audited_changes LIKE ?", class_name, '%'+ "#{object.class.to_s.foreign_key}: \n- \n- #{object.id}\n" +'%']}
  }

  scope :my_deleted_associations_sti, lambda { |object|
    {:conditions => ["audits.action = 'destroy' AND audits.audited_changes LIKE ?", '%'+ "#{object.class.base_class.to_s.foreign_key}: \n- \n- #{object.id}\n" +'%']}
  }

  scope :my_deleted_association_sti, lambda { |object, class_name|
    {:conditions => ["audits.action = 'destroy' AND audits.auditable_type = ? AND audits.audited_changes LIKE ?", class_name, '%'+ "#{object.class.base_class.to_s.foreign_key}: \n- \n- #{object.id}\n" +'%']}
  }

  def fix_timezone
    return unless audited_changes
    audited_changes.each do |name, value|
      if value.is_a? Array
        audited_changes[name] = [adjust_for_time(value[0]), adjust_for_time(value[1])]
      end
    end
  end

  def adjust_for_time(value)
    return unless value
    if value.is_a?(Date) || value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      value.to_s(:db)
    else
      value
    end
  end

  class << self

    def audits_for_deleted(deleted_audits)
      audit_list = Array.new
      deleted_audits.each do |del_audit|
        audit_list += Audit.find_all_by_auditable_type_and_auditable_id(del_audit.auditable_type, del_audit.auditable_id)
      end
      audit_list
    end

    def audits_for_deleted_associations_sti(object)
      the_audits = my_deleted_associations(object)
      if object.class != object.class.base_class
        the_audits += my_deleted_associations_sti(object)
      end
      the_audits
    end

    def audits_for_deleted_associations(object)
      Audit.audits_for_deleted(audits_for_deleted_associations_sti(object))
    end

    def deleted_audit_types(object)
      audits_for_deleted_associations_sti(object).map(&:auditable_type)
    end

    def audits_for_deleted_association(object, class_name)
      the_audits = my_deleted_association(object, class_name)
      if object.class != object.class.base_class
        the_audits += my_deleted_association_sti(object, class_name)
      end
      Audit.audits_for_deleted(the_audits)
    end

    # Returns the list of classes that are being audited
    def audited_classes
      audited_class_names.map(&:constantize)
    end

    # All audits made during the block called will be recorded as made
    # by +user+. This method is hopefully threadsafe, making it ideal
    # for background operations that require audit information.
    def as_user(user, &block)
      Thread.current[:acts_as_audited_user] = user

      yieldval = yield

      Thread.current[:acts_as_audited_user] = nil

      yieldval
    end

    # @private
    def reconstruct_attributes(audits)
      attributes = {}
      result = audits.collect do |audit|
        attributes.merge!(audit.new_attributes).merge!(:audit_version => audit.audit_version)
        yield attributes if block_given?
      end
      block_given? ? result : attributes
    end

    # @private
    def assign_revision_attributes(record, attributes)
      attributes.each do |attr, val|
        record = record.dup if record.frozen?

        if record.respond_to?("#{attr}=")
          record.attributes.has_key?(attr.to_s) ?
            record[attr] = val :
            record.send("#{attr}=", val)
        end
      end
      record
    end

  end

  # Allows user to be set to either a string or an ActiveRecord object
  # @private
  def user_as_string=(user)
    # reset both either way
    self.user_as_model = self.username = nil
    user.is_a?(ActiveRecord::Base) ?
      self.user_as_model = user :
      self.username = user
  end
  alias_method :user_as_model=, :user=
  alias_method :user=, :user_as_string=

  # @private
  def user_as_string
    self.user_as_model || self.username
  end
  alias_method :user_as_model, :user
  alias_method :user, :user_as_string

  # Return an instance of what the object looked like at this revision. If
  # the object has been destroyed, this will be a new record.
  def revision
    clazz = auditable_type.constantize
    ( clazz.find_by_id(auditable_id) || clazz.new ).tap do |m|
      Audit.assign_revision_attributes(m, self.class.reconstruct_attributes(ancestors).merge({:audit_version => audit_version}))
    end
  end

  # Return all audits older than the current one.
  def ancestors
    self.class.where(['auditable_id = ? and auditable_type = ? and audit_version <= ?',
      auditable_id, auditable_type, audit_version])
  end

  # Returns a hash of the changed attributes with the new values
  def new_attributes
    (audited_changes || {}).inject({}.with_indifferent_access) do |attrs,(attr,values)|
      attrs[attr] = values.is_a?(Array) ? values.last : values
      attrs
    end
  end

  # Returns a hash of the changed attributes with the old values
  def old_attributes
    (audited_changes || {}).inject({}.with_indifferent_access) do |attrs,(attr,values)|
      attrs[attr] = Array(values).first
      attrs
    end
  end

  def header_title
    if display_map[:display_title]
      if display_map[:display_title] != :none
        display_map[:display_title]
      else
        nil
      end
    else
      auditable_class
    end
  end

  def build_header
    {:actor => display_user, :action => (verbize_action),
      :date => created_at, :subject => header_title}
  end

  # an audit is displayable if
  # it is the create, has a sub header
  # or any details.
  def displayable?
    ((["create", "destroy"].include? action) && (is_parent? || header_title)) || display_details?
  end

  def display_header
    @display_header ||= build_header
  end

  def display_details?
    has_changes?
  end

  def has_changes?
    display_changes && !display_changes.empty?
  end

  def display_changes
    @display_changes ||= build_display_changes
  end

  def display_user
    actor = ""
    if user.is_a? String
      actor = user == "0" ? DEFAULT_USER_NAME : username
    else
      actor = user ? "#{user.first_name} #{user.last_name}" : DEFAULT_USER_NAME
    end
    actor
  end

private

  def set_audit_version_number
    max = self.class.maximum(:audit_version,
      :conditions => {
        :auditable_id => auditable_id,
        :auditable_type => auditable_type
      }) || 0
    self.audit_version = max + 1
  end

  def set_audit_user
    self.user = Thread.current[:acts_as_audited_user] if Thread.current[:acts_as_audited_user]
    nil # prevent stopping callback chains
  end

  def build_display_changes
    # cycle changes and put in an array
    change_list = Array.new
    audited_changes.each do |change|
      if (change_sentance = humanize_change(change))
        change_list << change_sentance
      end
    end
    change_list
  end

  # nice output of change hash
  def humanize_change(change)
    begin
      key = change[0]
      old = change[1][0]
      new = change[1][1]

      return if should_hide_key? key

      return {:subject => key.humanize.titleize} if should_hide_changes? key

      if use_mask? key
        old = apply_mask(key, old)
        new = apply_mask(key, new)
      else
        #a set of activities only apply if the key ends in _id.
        if key.match(/_id$/)
          if (changes = handle_belongs_to(key, old, new))
            key = changes[0]
            old = changes[1]
            new = changes[2]
          end
        end
      end
      # We want to show empty strings as nil
      new = set_to_nil? new
      old = set_to_nil? old
      if value_present old
        # "#{key.humanize.titleize} was changed from \"#{old}\" to \"#{new}\""
        {:subject => key.humanize.titleize, :old_value => old, :new_value => new}
      else
        if value_present new
          # "#{key.humanize.titleize} was set to \"#{new}\""
          {:subject => key.humanize.titleize, :new_value => new}
        end
      end
    rescue
      # puts "Hit Exception in humanize_change for #{audit} and change #{change}"
      # TODO: right now, we are basically hiding changes that we couldn't format
      # which is really an error condition.  We could uncomment the line below
      # and just put out an unrully format.
      # {:subject => "", :new_value => change}
    end
  end

  def value_present(value)
    !value.is_a?(NilClass)
  end

  def set_to_nil? (value)
    if value.is_a? String and value.empty?
      return nil
    else
      return value
    end
  end

  # Note: on the action, unless we are showing the title
  # of the associated object, all adds and deletes should be
  # set to updated.
  def verbize_action
    if "create" == action
      should_show_add_remove? ? "Added" : "Updated"
    elsif "update" == action
      "Updated"
    else
      should_show_add_remove? ? "Removed" : "Updated"
    end
  end

  # this is pretty geared around lookups, but could
  # be generified
  def handle_belongs_to(key, old, new)
    old_name = nil
    new_name = nil
    relationship = key_to_relationship(key)
    if relationship
      return if relationship.options[:polymorphic]
      if new
        new_name = guess_name(relationship.klass.find(new))
      end
      if old
        old_name = guess_name(relationship.klass.find(old))
      end
      key = key.sub("lookup_", "")
      key = key.sub("_id", "")
    end
    if new_name || old_name
      [key, old_name, new_name]
    end
  end

  def key_to_relationship(key)
    relationship_key = key.sub("_id", "")
    auditable_class.reflections[relationship_key.to_sym]
  end

  def auditable_class
    if auditable
      auditable.class
    else
      # need to deal with the fact that the auditable class is gone.
      auditable_type.constantize
    end
  end

  def guess_name(obj)
    if obj.respond_to? "full_name"
      return (obj.send :full_name)
    end
    if obj.respond_to? "name"
      return (obj.send :name)
    end
    if obj.respond_to? "value"
      return (obj.send :value)
    end
    if obj.respond_to? "title"
      return (obj.send :title)
    end
  end

  def should_show_add_remove?
    is_parent? || header_title
  end

  def should_hide_key?(key)
    display_map[:hide] && display_map[:hide].include?(key.to_sym)
  end

  def should_hide_changes?(key)
    display_map[:key_only] && display_map[:key_only].include?(key.to_sym)
  end

  def is_parent?
    display_map[:parent]
  end

  def use_mask?(key)
    display_map[:mask] && display_map[:mask].keys.include?(key.to_sym)
  end

  def apply_mask(key, value)
    display_map[:mask][key.to_sym][value] if value
  end
end
