class SpentTimeController < ApplicationController

  helper :timelog
  include TimelogHelper
  helper :spent_time
  include SpentTimeHelper
  helper :custom_fields
  include CustomFieldsHelper

  # Show the initial form.
  # * If user has permissions to see spent time for every project
  # the users combobox is filled with all the users.
  # * If user has permissions to see other members' spent times of the projects he works in,
  # the users combobox is filled with their co-workers
  # * If the user only has permissions to see his own report, the users' combobox is filled with the user himself.
  def index
    @user = User.current
    @users = []
    if authorized_for?(:view_every_project_spent_time)
      logger.info("User is authorized for viewing every project spent time")
      @users = User.active.order(:firstname)
    elsif authorized_for?(:view_others_spent_time)
      logger.info("User is authorized for viewing other team mates spent time")
      projects = User.current.projects
      projects.each {|project| @users.concat(project.users)}
      @users.uniq!
      @users.sort!
    else
      logger.info("User is authorized for viewing only her spent time")
      @users = [@user]
    end
    params[:period] ||= '7_days'
    make_time_entry_report(nil, nil, User.current)
    @assigned_issues = []
    find_assigned_issues_by_project(nil)
    @same_user = true
    @time_entry = TimeEntry.new
  end

  # Show the report of spent time between two dates for an user
  def report
    @user = User.current
    projects = nil
    if authorized_for?(:view_every_project_spent_time)
      # all project, which are not archived
      projects = Project.where('status!=9')
    elsif authorized_for?(:view_others_spent_time)
      projects = User.current.projects
    end
    report_user = User.find(params[:user])
    make_time_entry_report(params[:from], params[:to], report_user, projects)
    another_user = User.find(params[:user])
    @same_user = (@user.id == another_user.id)
    respond_to do |format|
      format.js
    end
  end

  # Delete a time entry
  def destroy_entry
    @time_entry = TimeEntry.find(params[:id])
    render_404 and return unless @time_entry
    render_403 and return unless @time_entry.editable_by?(User.current)
    @time_entry.destroy

    @user = User.current
    @from = params[:from].to_s.to_date
    @to = params[:to].to_s.to_date
    make_time_entry_report(params[:from], params[:to], @user)
    respond_to do |format|
      format.js
    end
  rescue ::ActionController::RedirectBackError
    redirect_to :action => 'index'
  end

  # Create a new time entry
  def create_entry
    begin
      @user = User.current
      if(params[:project_id].to_i < 0)
        params[:project_id] = Issue.find(params[:issue_id]).project_id
      end

      begin
        @time_entry_date = params[:time_entry_spent_on].to_s.to_date
      rescue
        raise 'invalid_date_error'
      end

      raise 'invalid_hours_error' unless is_numeric?(params[:time_entry][:hours].to_f)
      params[:time_entry][:spent_on] = @time_entry_date
      @from = params[:from].to_s.to_date
      @to = params[:to].to_s.to_date

      begin
        @project = Project.find(params[:project_id])
        unless allowed_project?(params[:project_id])
          raise t('not_allowed_error', :project => @project)
        end
      rescue ActiveRecord::RecordNotFound
        raise t('cannot_find_project_error', project_id => params[:project_id])
      end

      @time_entry = TimeEntry.new(:user => @user, :author => @user, :project => @project)
      @time_entry.safe_attributes = params[:time_entry]

      issue_id = (params[:issue_id] == nil) ? 0 : params[:issue_id].to_i
      if issue_id > 0
        begin
          @issue = Issue.find(issue_id)
        rescue ActiveRecord::RecordNotFound
          raise t('issue_not_found_error', :issue_id => issue_id)
        end

        if @project.id == @issue.project_id
          @time_entry.issue = @issue
        else
          raise t('issue_not_in_project_error', issue => @issue, project => @project)
        end
      end
      if issue_id == 0
        raise "Validation failed: No issue specified"
      end

      if @time_entry.project && !@user.allowed_to?(:log_time, @time_entry.project)
        render_403
        return
      end
      logger.info("Saving time entry for user: #{@time_entry.user}")
      if @time_entry.save!
        flash[:notice] = l('time_entry_added_notice')
        logger.info('Everything went fine rendering report result')
        respond_to do |format|
          if @time_entry_date > @to
            @to = @time_entry_date
          elsif @time_entry_date < @from
            @from = @time_entry_date
          end
          make_time_entry_report(@from, @to, @user)
          logger.info('Rendering JS activities...')
          format.js
          return
        end
      end
    rescue Exception => exception
      logger.info("Error saving time entry: #{exception}")
      respond_to do |format|
        flash[:error] = exception.message
        format.js {render 'spent_time/create_entry_error'}
      end
    end
  end

  # Update the project's issues when another project is selected
  def update_project_issues
    @to = params[:to].to_date
    @from = params[:from].to_date
    begin
      project = Project.find(params[:project_id])
    rescue
      project = nil
    end
    @time_entry = TimeEntry.new(:project => project)
    find_assigned_issues_by_project(params[:project_id])
    respond_to do |format|
      format.js
    end
  end

  private

  def is_numeric?(obj)
    obj.to_s.match(/\A[+-]?\d+?(\.\d+)?\Z/) == nil ? false : true
  end

  def allowed_project?(project_id)
    project = Project.find(project_id)
    allowed = project.allows_to?(:log_time)
    allowed ? project : nil
  end

end
