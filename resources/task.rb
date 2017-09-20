property :task_name, String, desired_state: false, identity: true, name_attribute: true
property :task_source, String, desired_state: false, identity: true, default: ''.freeze
property :task_crontab, String, desired_state: false, identity: true, default: '0 1 * * * ?'.freeze
property :api_endpoint, String, desired_state: false, identity: true,
                                default: lazy { node['nexus3']['api']['endpoint'] }
property :api_username, String, desired_state: false, identity: true,
                                default: lazy { node['nexus3']['api']['username'] }
property :api_password, String, desired_state: false, identity: true, sensitive: true,
                                default: lazy { node['nexus3']['api']['password'] }

load_current_value do |desired|
  api_endpoint desired.api_endpoint
  api_username desired.api_username
  api_password desired.api_password

  def apiclient
    @apiclient ||= ::Nexus3::Api.new(api_endpoint, api_username, api_password)
  end

  begin
    res = apiclient.run_script('get_task', desired.task_name)
    current_value_does_not_exist! if res == 'null'
    config = JSON.parse(res)
    ::Chef::Log.warn "Config is: #{config}"
    task_name config['.name']
    task_source config['source']
  # We rescue here because during the first run, the task will not exist yet, so we let Chef know that
  # the resource has to be created.
  rescue LoadError, ::Nexus3::ApiError => e
    ::Chef::Log.warn "A '#{e.class}' occured: #{e.message}"
    current_value_does_not_exist!
  end
end

action :create do
  init

  converge_if_changed do
    nexus3_api "upsert_task #{new_resource.task_name}" do
      script_name 'upsert_task'
      args name: new_resource.task_name,
           source: new_resource.task_source,
           crontab: new_resource.task_crontab

      action %i(create run)
      endpoint new_resource.api_endpoint
      username new_resource.api_username
      password new_resource.api_password

      content <<-EOS
// Freely adapted from
// https://github.com/savoirfairelinux/ansible-nexus3-oss/blob/master/files/groovy/create_task.groovy
import org.sonatype.nexus.scheduling.TaskConfiguration;
import org.sonatype.nexus.scheduling.TaskInfo;
import org.sonatype.nexus.scheduling.TaskScheduler;
import org.sonatype.nexus.scheduling.schedule.Schedule;

import groovy.json.JsonSlurper;

def params = new JsonSlurper().parseText(args);

TaskScheduler taskScheduler = container.lookup(TaskScheduler.class.getName());
TaskInfo existingTask = taskScheduler.listsTasks().find { TaskInfo taskInfo ->
   taskInfo.getName() == params.name;
}
if (existingTask && !existingTask.remove()) {
   throw new RuntimeException("Could not remove currently running task: " + params.name);
}

TaskConfiguration taskConfiguration = taskScheduler.createTaskConfigurationInstance('script');
taskConfiguration.setName(params.name);
taskConfiguration.setString('source', params.source);
Schedule schedule = taskScheduler.scheduleFactory.cron(new Date(), params.crontab);

taskScheduler.scheduleTask(taskConfiguration, schedule);
      EOS
    end
  end
end

action :delete do
  init

  converge_if_changed do
    nexus3_api "delete_task #{new_resource.task_name}" do
      action %i(create run)
      script_name 'delete_task'
      args new_resource.task_name

      content <<-EOS
import groovy.json.JsonSlurper;

import org.sonatype.nexus.scheduling.TaskConfiguration;
import org.sonatype.nexus.scheduling.TaskInfo;
import org.sonatype.nexus.scheduling.TaskScheduler;

TaskScheduler taskScheduler = container.lookup(TaskScheduler.class.getName());
TaskInfo existingTask = taskScheduler.listsTasks().find { TaskInfo taskInfo ->
    taskInfo.getName() == args;
}

if (existingTask && !existingTask.remove()) {
   throw new RuntimeException("Could not remove currently running task: " + args);
}
    EOS

      endpoint new_resource.api_endpoint
      username new_resource.api_username
      password new_resource.api_password

      not_if { current_resource.nil? }
    end
  end
end

action_class do
  def init
    chef_gem 'httpclient' do
      compile_time true
    end

    nexus3_api "get_task #{new_resource.task_name}" do
      action :create
      script_name 'get_task'
      args new_resource.task_name
      endpoint new_resource.api_endpoint
      username new_resource.api_username
      password new_resource.api_password

      content <<-EOS
import org.sonatype.nexus.scheduling.TaskConfiguration;
import org.sonatype.nexus.scheduling.TaskInfo;
import org.sonatype.nexus.scheduling.TaskScheduler;

import groovy.json.JsonOutput;

TaskScheduler taskScheduler = container.lookup(TaskScheduler.class.getName());

TaskInfo existingTask = taskScheduler.listsTasks().find { TaskInfo taskInfo ->
    taskInfo.getName() == args;
}

if (existingTask) {
return JsonOutput.toJson(existingTask.getConfiguration().asMap());
}
      EOS
    end
  end
end
