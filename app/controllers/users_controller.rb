class UsersController < ApplicationController
  
  skip_before_filter :update_last_seen_at, :only => [:create, :new, :activate, :sudo]
  before_filter :find_user,      :except => [:new, :create, :sudo]
  
  before_filter :login_required, :except => [:index, :show, :new, :create, :activate, :bio]
  skip_before_filter :login_by_token, :only => :sudo
  
  rescue_from NoMethodError, :with => :user_not_found

  def index
    @page_title = 'the music makers and music lovers of alonetone'
    @tab = 'browse'
    @users = User.paginate_by_params(params)
    flash[:info] = "Want to see your pretty face show up here?<br/> Edit <a href='#{edit_user_path(current_user)}'>your profile</a>" unless current_user = :false || current_user.has_pic?
    respond_to do |format|
      format.html do
        @user_count = User.count
        @active     = User.count(:all, :conditions => "assets_count > 0", :include => :pic)
      end
      format.fbml
      format.xml do
        @users = User.search(params[:q], :limit => 25)
        render :xml => @users.to_xml
      end
      format.js do
          render :partial => 'users.html.erb'
      end
     # format.fbml do
     #   @users = User.paginate(:all, :per_page => 10, :order => 'listens_count DESC', :page => params[:page])
     # end
    end
  end

  def show
    respond_to do |format|
      format.html do
        @page_title = @user.name + "'s latest music and playlists"
        @tab = 'your_stuff' if current_user == @user
        @assets = @user.assets.find(:all, :limit => 5)
        @playlists = @user.playlists.public.find(:all)
        @listens = @user.listens.find(:all, :limit =>5)
        @track_plays = @user.track_plays.from_user.find(:all, :limit =>10) 
        @favorites = Track.favorites.find_all_by_user_id(@user.id, :limit => 5)
        @comments = @user.comments.find_all_by_spam(false, :limit => 10)
        render
      end
      format.xml { @assets = @user.assets.find(:all, :order => 'created_at DESC')}
      format.rss { @assets = @user.assets.find(:all, :order => 'created_at DESC')}
      format.fbml do
        @assets = @user.assets.find(:all)
      end
      format.js do  render :update do |page| 
          page.replace 'user_latest', :partial => "latest"
        end
      end
    end
  end

  def new
    @user = User.new
    @page_title = "Sign up to upload your mp3s"
    flash.now[:error] = "Join alonetone to upload and create playlists (it is quick: about 45 seconds)" if params[:new]
  end
  
  
  def create
    respond_to do |format|
      format.html do
        @user = params[:user].blank? ? User.find_by_email(params[:email]) : User.new(params[:user])
        flash[:error] = "I could not find an account with the email address '#{CGI.escapeHTML params[:email]}'. Did you type it correctly?" if params[:email] and not @user
        redirect_to login_path and return unless @user
        @user.login = params[:user][:login] unless params[:user].blank?
        @user.reset_token! 
        begin
          UserMailer.deliver_signup(@user)
        rescue Net::SMTPFatalError => e
          flash[:error] = "A permanent error occured while sending the signup message to '#{CGI.escapeHTML @user.email}'. Please check the e-mail address."
          redirect_to :action => "new"
        rescue Net::SMTPServerBusy, Net::SMTPUnknownError, \
          Net::SMTPSyntaxError, TimeoutError => e
          flash[:error] = "The signup message cannot be sent to '#{CGI.escapeHTML @user.email}' at this moment. Please, try again later."
          redirect_to :action => "new"
        end
        flash[:ok] = "We just sent you an email to '#{CGI.escapeHTML @user.email}'.<br/><br/>You just have to click the link in the email, and the hard work is over! <br/> Note: check your junk/spam inbox if you don't see a new email right away."
      end
    end
    rescue ActiveRecord::RecordInvalid
      flash[:error] = "Whups, there was a small issue"
      render :action => 'new'
  end
  
  
  def activate
    self.current_user = User.find_by_activation_code(params[:activation_code])
    if current_user != false && !current_user.activated?
      current_user.activate
      flash[:ok] = "Whew! All done, your account is activated. Go ahead and upload your first track."
      redirect_to new_user_track_path(current_user)
    else 
      flash[:error] = "Hm. Activation didn't work. Maybe your account is already activated?"
      redirect_to default_url
    end
  end
  
  def edit

  end
  
  def bio
    @page_title = "All about #{@user.name}"
  end
  
  def attach_pic
    @pic = @user.build_pic(params[:pic])
    if @pic.save
      flash[:ok] = 'Pic updated!'
    else
      flash[:error] = 'Pic not updated!'      
    end
    redirect_to edit_user_path(@user)
  end
  
  
  def update
    @user.attributes = params[:user]
    # temp fix to let people with dumb usernames change them
    # @user.login = params[:user][:login] if not @user.valid? and @user.errors.on(:login)
    respond_to do |format|
      format.html do 
        if @user.save 
          flash[:ok] = "Sweet, updated" 
          redirect_to edit_user_path(@user)
        else
          flash[:error] = "Not so fast, young one"
          render :action => :edit
        end
      end
      format.js do
        @user.save ? (return head(:ok)) : (return head(:bad_request))
      end
    end
  end
  
  def toggle_favorite
    return false unless Asset.find(params[:asset_id]) # no bullshit
    existing_track = @user.tracks.find(:first, :conditions => {:asset_id => params[:asset_id], :is_favorite => true})
    if existing_track  
      existing_track.destroy && Asset.decrement_counter(:favorites_count, params[:asset_id])
    else
      favs = Playlist.find_or_create_by_user_id_and_is_favorite(:user_id => @user.id, :is_favorite => true) 
      added_fav = favs.tracks.create(:asset_id => params[:asset_id], :is_favorite => true, :user_id => @user.id)
      Asset.increment_counter(:favorites_count, params[:asset_id]) if added_fav
    end
    render :nothing => true
  end

  def destroy
    return unless admin?
    @user.destroy
    respond_to do |format|
      format.html { redirect_to users_path }
      format.xml  { head 200 }
    end
  end
  
  def sudo
    @to_user = User.find_by_login(params[:login] || params[:id])
    redirect_to :back and return false unless (current_user.admin? || session[:sudo]) && @to_user
    flash[:ok] = "Sudo to #{@to_user.name}" if sudo_to(@to_user)
    redirect_to :back
  end

  protected
    def authorized?
      admin? || (!%w(destroy admin sudo).include?(action_name) && logged_in? && (current_user.id.to_s == @user.id.to_s))
    end
    
    def display_user_home_or_index
      if params[:login] && User.find_by_login(params[:login])
        redirect_to user_home_url(params[:user])
      else
        redirect_to users_url
      end
    end
    
end
