module ReportController::Reports
  include DataTableHelper
  extend ActiveSupport::Concern

  include_concern 'Editor'

  def miq_report_run
    assert_privileges("miq_report_run")
    self.x_active_tree = :reports_tree
    @sb[:active_tab] = "saved_reports"
    rep = MiqReport.for_user(current_user).find(params[:id])
    rep.queue_generate_table(:userid => session[:userid])
    nodes = x_node.split('-')
    get_all_reps(nodes[4])
    @sb[:selected_rep_id] = nodes[3].split('_').last
    if role_allows?(:feature => "miq_report_widget_editor")
      # all widgets for this report
      get_all_widgets("report", nodes[3].split('_').last)
    end
    add_flash(_("Report has been successfully queued to run"))
    replace_right_cell(:replace_trees => %i[reports savedreports])
  end

  def show_preview
    assert_privileges(session.fetch_path(:edit, :rpt_id) ? "miq_report_edit" : "miq_report_new")

    unless params[:task_id]                       # First time thru, kick off the report generate task
      @rpt = create_report_object                 # Build a report object from the latest edit fields
      initiate_wait_for_task(:task_id => @rpt.async_generate_table(:userid     => session[:userid],
                                                                   :session_id => request.session_options[:id],
                                                                   :limit      => 50,
                                                                   :mode       => "adhoc"))
      return
    end
    miq_task = MiqTask.find(params[:task_id])     # Not first time, read the task record
    rpt = miq_task.task_results
    if !miq_task.results_ready?
      add_flash(_("Report preview generation returned: Status [%{status}] Message [%{message}]") % {:status => miq_task.status, :message => miq_task.message},
                :error)
    else
      rr = miq_task.miq_report_result
      table_content = report_build_html_table(rr.report, rr.html_rows(:page => 1, :per_page => 100).join)
      @html = update_content(table_content, :striped, 'preview')
      if !rpt.graph.nil? && rpt.graph[:type].present? # If graph present
        # FIXME: UNTESTED!!!
        rpt.to_chart(settings(:display, :reporttheme), false, MiqReport.graph_options) # Generate the chart
        @edit[:chart_data] = rpt.chart
      else
        @edit[:chart_data] = nil
      end
    end
    miq_task.destroy
    render :update do |page|
      page << javascript_prologue
      page.replace_html("form_preview", :partial => "form_preview")
      page << "miqSparkle(false);"
    end
  end

  def miq_report_delete
    assert_privileges("miq_report_delete")
    rpt = MiqReport.for_user(current_user).find(params[:id])

    if rpt.miq_widgets.exists?
      render_flash(_("Report cannot be deleted if it's being used by one or more Widgets"), :error)
    else
      begin
        raise StandardError, _("Default Report \"%{name}\" cannot be deleted") % {:name => rpt.name} if rpt.rpt_type == "Default"
        rpt_name = rpt.name
        menu_repname_update(rpt_name, nil)
        audit = {:event => "report_record_delete", :message => "[#{rpt_name}] Record deleted", :target_id => rpt.id, :target_class => "MiqReport", :userid => session[:userid]}
        rpt.destroy
      rescue => bang
        add_flash(_("Report \"%{name}\": Error during 'miq_report_delete': %{message}") %
                    {:name => rpt_name, :message => bang.message}, :error)
        javascript_flash
        return
      else
        AuditEvent.success(audit)
        add_flash(_("Report \"%{name}\": Delete successful") % {:name => rpt_name})
      end
      params[:id] = nil
      nodes = x_node.split('_')
      self.x_node = "#{nodes[0]}_#{nodes[1]}"
      replace_right_cell(:replace_trees => [:reports])
    end
  end

  def download_report
    assert_privileges("miq_report_export")
    @yaml_string = MiqReport.export_to_yaml(params[:id] ? [params[:id]] : @sb[:choices_chosen], MiqReport)
    file_name    = "Reports_#{format_timezone(Time.now, Time.zone, "export_filename")}.yaml"
    disable_client_cache
    send_data(@yaml_string, :filename => file_name)
  end

  # Generating sample chart
  def sample_chart
    assert_privileges("view_graph")

    render ManageIQ::Reporting::Charting.render_format => ManageIQ::Reporting::Charting.sample_chart(@edit[:new], settings(:display, :reporttheme))
  end

  # generate preview chart when editing report
  def preview_chart
    assert_privileges("view_graph")

    render ManageIQ::Reporting::Charting.render_format => session[:edit][:chart_data]
    session[:edit][:chart_data] = nil
  end

  # get saved reports for a specific report
  def get_all_reps(nodeid = nil)
    # set nodeid from @sb, incase sort was pressed
    nodeid = x_active_tree == :reports_tree ? x_node.split('-').last : x_node.split('-').last.split('_')[0] if nodeid.nil?
    @sb[:miq_report_id] = nodeid
    @record = @miq_report = MiqReport.for_user(current_user).find(@sb[:miq_report_id])
    if @sb[:active_tab] == "saved_reports" || x_active_tree == :savedreports_tree
      @force_no_grid_xml   = true
      @no_checkboxes = !role_allows?(:feature => "miq_report_saved_reports_admin", :any => true)

      if params[:ppsetting]                                             # User selected new per page value
        @items_per_page = params[:ppsetting].to_i                       # Set the new per page value
        @settings.store_path(:perpage, :list, @items_per_page) # Set the per page setting for this gtl type
      end

      @sortcol = session["#{x_active_tree}_sortcol".to_sym].nil? ? ReportController::DEFAULT_SORT_COLUMN_NUMBER : session["#{x_active_tree}_sortcol".to_sym].to_i
      @sortdir = session["#{x_active_tree}_sortdir".to_sym].nil? ? ReportController::DEFAULT_SORT_ORDER : session["#{x_active_tree}_sortdir".to_sym]

      report_id = nodeid.split('_')[0]
      @view, @pages = get_view(MiqReportResult, :named_scope => [[:with_current_user_groups_and_report, report_id]])
      @sb[:timezone_abbr] = @timezone_abbr if @timezone_abbr

      @current_page = @pages[:current] unless @pages.nil? # save the current page number
      session["#{x_active_tree}_sortcol".to_sym] = @sortcol
      session["#{x_active_tree}_sortdir".to_sym] = @sortdir
    end

    if @sb[:active_tab] == "report_info"
      schedules = MiqSchedule.where(:resource_type => "MiqReport")
      schedules = schedules.where(:userid => current_userid) unless super_admin_user?
      @schedules = schedules.select { |s| s.filter.exp["="]["value"].to_i == @miq_report.id.to_i }.sort_by(&:name)

      @widget_nodes = @miq_report.miq_widgets.to_a
    end

    @sb[:tree_typ]   = "reports"
    @right_cell_text = _("Report \"%{name}\"") % {:name => @miq_report.name}
  end

  def rep_change_tab
    assert_privileges("miq_report_view")

    @sb[:active_tab] = params[:tab_id]
    replace_right_cell
  end

  private

  def menu_repname_update(old_name, new_name)
    # @param old_name [String] old name for the report
    # @param new_name [String, Nil] new name for the report. nil if it was deleted

    all_roles = MiqGroup.non_tenant_groups_in_my_region
    all_roles.each do |role|
      rec = MiqGroup.find_by(:description => role.name)
      menu = rec.settings[:report_menus] if rec.settings
      next if menu.nil?
      menu.each_with_index do |lvl1, i|
        lvl1[1].each_with_index do |lvl2, j|
          lvl2[1].each_with_index do |rep, k|
            if rep == old_name
              if new_name.nil?
                menu[i][1][j][1].delete_at(k)
              else
                menu[i][1][j][1][k] = new_name
              end
            end
          end
        end
      end
      rec.settings[:report_menus] = menu
      rec.save!
    end
  end

  def friendly_model_name(model)
    # First part is a model name
    tables = model.split(".")
    retname = ""
    # The rest are table names
    if tables.length > 1
      tables[1..-1].each do |t|
        retname += "." if retname.present?
        retname += Dictionary.gettext(t, :type => :table, :notfound => :titleize)
      end
    end
    retname = retname.blank? ? " " : retname + " : " # Use space for base fields, add : to others
    retname
  end

  # Create a report object from the current edit fields
  def create_report_object
    rpt_rec = MiqReport.new  # Create a new report record
    set_record_vars(rpt_rec) # Set the fields into the record
    rpt_rec                  # Create a report object from the record
  end

  # Build the main reports tree
  # FIXME: get rid of the data passing through session and delete this method
  def build_reports_tree
    populate_reports_menu
    TreeBuilderReportReports.new('reports_tree', @sb)
  end
end
