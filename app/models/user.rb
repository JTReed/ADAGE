class User < ActiveRecord::Base
  include Pacecar
  # Include default devise modules. Others available are:
  # :token_authenticatable, :encryptable, :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable,
         :omniauthable,
         :token_authenticatable, :authentication_keys => [:login]

  before_save :ensure_authentication_token

  attr_accessor :login
  # Setup accessible (or protected) attributes for your model

  attr_accessible :email, :player_name, :password, :password_confirmation, :remember_me, :authentication_token, :role_ids, :consented, :guest, :group_ids


  # for pathfinder, remove when sso is complete
  before_create :update_control_group
  before_save :set_default_role

  before_validation :email_or_player_name, :on => :create
  validates :player_name, presence: true, uniqueness: {case_sensitive: false}

  has_many :assignments
  has_and_belongs_to_many :roles
  has_many :access_tokens
  has_many :social_access_tokens
  has_and_belongs_to_many :groups

  def role?(role)
      return !!self.roles.find_by_name(role.name)
  end

  def researcher_role?
    return !!self.roles.find_by_type('ResearcherRole')
  end

  def teacher?
    return !!self.roles.find_by_name('teacher')
  end

  def researcher?
    return !!self.roles.find_by_name('researcher')
  end

  def developer?
    return !!self.roles.find_by_name('researdevelopercher')
  end

  def admin?
    return !!self.roles.find_by_name('admin')
  end

  def data
    AdaData.where("user_id" => self.id)
  end

  def saves
    SaveData.where("user_id" => self.id)
  end

  def progenitor_data
    AdaData.where("user_id" => self.id, "gameName" => "ProgenitorX")
  end


  def self.with_login(login)
    where(["lower(player_name) = :login OR lower(email) = :login", login: login.strip.downcase])
  end

  def self.find_for_database_authentication(warden_conditions)
    conditions = warden_conditions.dup
    login = conditions.delete(:login)
    where(conditions).with_login(login).first
  end

  def self.find_for_facebook_oauth(auth, signed_in_resource=nil)
    user = User.where(email: auth.info.email).first

    if user.blank?
      password =  Devise.friendly_token[0,20]
      user = User.create(player_name:auth.extra.raw_info.username,
                          email:auth.info.email,
                           password:password,
                           password_confirm:password
                        )
    end


    fb_access = user.social_access_tokens.where(provider: auth.provider).first
    if fb_access.present?
      fb_access.update_all(expired_at: Time.at(auth.credentials.expires_at),access_token: auth.credentials.token)
    else
      fb_access = SocialAccessToken.create(
        user: user,
        provider: auth.provider,
        uid: auth.uid,
        access_token: auth.credentials.token,
        expired_at: Time.at(auth.credentials.expires_at)
      )
    end
    user
  end

  def self.create_guest
    #generate token since the playername and email have to be unique
    name = ZooPass.generate_name
    while User.where(player_name: name).first != nil
      name = ZooPass.generate_name
    end
    guest = User.create(
      player_name: name,
      email: name+'@guest.com',
      guest: true,
    )
    return guest
  end


  def self.find_for_brainpop_auth(player_id, signed_in_resource=nil)

    access_token = SocialAccessToken.where(provider: 'brainpop', uid: player_id).first
    user = nil
    if access_token == nil
      user = User.create_guest
      access_token = SocialAccessToken.create(
        user: user,
        provider: 'brainpop',
        uid: player_id,
        access_token: player_id
      )
    else
      user = access_token.user
    end

    return user

  end

  def self.find_for_google_oauth2(auth, signed_in_resource=nil)
    user = User.where(email: auth.info.email).first

    if user.blank?
        user = User.create(player_name: auth.info["name"],
             email: auth.info["email"],
             password: Devise.friendly_token[0,20]
            )
    end
      gp_access = user.social_access_tokens.where(provider: auth.provider)
      if gp_access.present?
        gp_access.update_all(expired_at: Time.at(auth.credentials.expires_at),access_token: auth.credentials.token)
      else
        gp_access = SocialAccessToken.create(
          user: user,
          provider: auth.provider,
          uid: auth.uid,
          access_token: auth.credentials.token,
          expired_at: Time.at(auth.credentials.expires_at)
        )
      end

      user
  end

  def add_to_group(code)
    @group = Group.find_by_code(code)
    unless @group.nil? || self.groups.include?(@group)
      self.groups << @group
    end
  end

  def data_to_csv(csv, gameName, schema='')
    keys = Hash.new
    data = self.data.where(gameName: gameName)
    if schema.present?
      data = data.where(schema: schema)
    end
    data = data.asc(:timestamp)
    types = data.distinct(:key)
    examples = Array.new
    types.each do |type|
      ex = data.where(key: type).first
      if ex != nil
        examples << ex
      end
    end
    all_attrs = Array.new
    examples.each do |e|
      e.attributes.keys.each do |k|
        all_attrs << k
      end
    end
    csv << ["player", "epoch time"] + all_attrs.uniq
    data.each do |entry|
      out = Array.new
      out << self.player_name
      if entry.respond_to?('timestamp')
        if entry.timestamp.to_s.include?(':')
          out << DateTime.strptime(entry.timestamp.to_s, "%m/%d/%Y %H:%M:%S").to_time.to_i
        else
          out << 'does not compute'
        end
      else
        out << 'no timestamp'
      end
      all_attrs.uniq.each do |attr|
        if entry.attributes.keys.include?(attr)
          out << entry.attributes[attr]
        else
          out << ""
        end
      end
      csv << out
    end
    return csv
  end


  #returns session for this player
  def session_information(gameName= nil, gameVersion= nil)
    data = self.data.asc(:timestamp)
    if gameName != nil
      data = data.where(gameName: gameName).asc(:timestamp)
    end

    if gameVersion != nil
      data = data.where(gameVersion: gameVersion) + data.where(schema: gameVersion) 
    end

    puts 'data count: ' + data.count.to_s

    session_times = Hash.new
    sessions = data.distinct(:session_token).sort
    data = data.entries
    sessions.each do |token|
      session_logs = data.select{ |d| d.session_token.include?(token) }
      if session_logs.first.respond_to?('ADAVersion')
      
        if session_logs.first.ADAVersion.include?('drunken_dolphin')
          end_time =  Time.at(session_logs.last.timestamp.to_i)  
          start_time = Time.at(session_logs.first.timestamp.to_i)  
          hash = start_time
          minutes = ((end_time - start_time)/1.minute).round 
          if session_times[hash] != nil
            session_times[hash] = minutes 
          else
            session_times[hash] = minutes
          end
        end

        if session_logs.first.ADAVersion.include?('bodacious_bonobo')
          end_time =  DateTime.strptime(session_logs.last.timestamp, "%m/%d/%Y %H:%M:%S").to_time 
          start_time = DateTime.strptime(session_logs.first.timestamp, "%m/%d/%Y %H:%M:%S").to_time 
          puts start_time
          puts end_time
          hash = start_time  
          minutes = ((end_time - start_time)/1.minute).round 
          if session_times[hash] != nil
            session_times[hash] =  minutes 
          else
            session_times[hash] = minutes
          end

        end 
      end

    end

    return session_times
  end

  def context_information(game_name= nil, game_version=nil)
    data = self.data
    if game_name != nil
      data = data.where(gameName: game_name).asc(:timestamp)
    end

    if game_version != nil
      data = data.where(gameVersion: game_version) + data.where(schema: game_version) 
    end

    data = data.entries

    
    if data.first.respond_to?('ADAVersion')
      if data.first.ADAVersion.include?('drunken_dolphin')
        context_logs = data.select { |l| l.ada_base_types.include?('ADAGEContext') }
      else
        context_logs = data.select { |l| l.ada_base_type.include?('ADAStartUnit') or l.ada_base_type.include?('ADAEndUnit') }
      end
    end

    contexts = Hash.new(0)
    context_stack = Array.new

    
    context_logs.each do |q|
      if q.ada_base_types.include?('ADAGEContextStart') or q.ada_base_types.include?('ADAGEStartUnit') 
        unless context_stack.include?(q.name)
          context_stack << q.name
          contexts[q.name+'_start'] = contexts[q.name+'_start'] + 1 
        end
      else
        if context_stack.include?(q.name)
          context_stack = context_stack.delete(q.name)
          contexts[q.name+'_end'] = contexts[q.name+'_end'] + 1 
          if q.respond_to?('success')
            puts q.success
            if q.success == true
              contexts[q.name+'_success'] = contexts[q.name+'_success'] + 1
            else
              contexts[q.name+'_fail'] = contexts[q.name+'_fail'] + 1
            end  
          end
        end
      end
    end

    return contexts


  end

  private

  #override devise password to allow guest acounts with nil passwords
  def password_required?
    super && !self.guest
  end

  #override devise password to allow guest acounts with nil emails
  def email_required?
    super && !self.guest
  end

  def update_control_group
    if self.control_group.nil?
      if rand() < 0.5
        self.control_group = false
      else
        self.control_group = true
      end
    end

    true
  end

  def set_default_role
    if self.new_record?
      default_role = Role.where(name: 'player').first || Role.create(name: 'player')
      if !self.roles.present?
        self.roles = [default_role]
      elsif !self.role?(default_role)
        self.roles << default_role
      end
    end
  end

  def email_or_player_name
    if self.email.blank? && self.player_name.present?
      self.email = self.player_name + "@stu.de.nt"
    elsif self.player_name.blank? && self.email.present? && self.email.match("@")
      self.player_name = self.email.split("@").first
    end
  end

end
