module Reina
  class SignatureError < StandardError
    def message
      'Signatures do not match'
    end
  end

  class UnsupportedEventError < StandardError; end

  class GitHubController
    COMMAND_PREFIX = 'reina:'.freeze
    DESTROY_TRIGGER = "#{COMMAND_PREFIX} destroy!".freeze
    DEPLOY_TRIGGER = "#{COMMAND_PREFIX} d ".freeze
    SINGLE_DEPLOY_TRIGGER = "#{COMMAND_PREFIX} r ".freeze
    EVENTS = %w(issues issue_comment pull_request).freeze

    def initialize(config)
      @config = config
    end

    def dispatch(request)
      @request = request

      raise UnsupportedEventError unless EVENTS.include?(event)

      authenticate!

      if destroy_requested?
        destroy!
      elsif deploy_requested?
        deploy!
      elsif single_deploy_requested?
        deploy!(true)
      elsif issue_closed?
        destroy!
      elsif is_comment?
        reply_unknown_command
      end
    end

    def deployed_app_name(app)
      "#{CONFIG[:app_name_prefix]}#{app.name}-#{issue_number}"
    end

    def deployed_url(app)
      "https://#{deployed_app_name(app)}.herokuapp.com/#{app.deployed_url_suffix}"
    end

    def heroku_url(app, path = "")
      "https://dashboard.heroku.com/apps/#{deployed_app_name(app)}/#{path}"
    end

    private

    attr_reader :config, :request

    def authenticate!
      hash = OpenSSL::HMAC.hexdigest(hmac_digest, config[:webhook_secret], raw_payload)
      hash.prepend('sha1=')
      raise SignatureError unless Rack::Utils.secure_compare(hash, signature)
    end

    def destroy_requested?
      action == 'created'.freeze && comment_body.start_with?(DESTROY_TRIGGER)
    end

    def deploy_requested?
      action == 'created'.freeze && comment_body.start_with?(DEPLOY_TRIGGER)
    end

    def single_deploy_requested?
      action == 'created'.freeze && comment_body.start_with?(SINGLE_DEPLOY_TRIGGER)
    end

    def issue_closed?
      action == 'closed'.freeze
    end

    def reply_unknown_command
      return unless action == 'created'
      return unless comment_body.start_with?(COMMAND_PREFIX)
      command = comment_body[COMMAND_PREFIX.size .. -1].lines.first.strip
      post_reply("Unknown command: '#{command}'")
    end

    def post_reply(msg)
      should_comment = config[:oauth_token].present?
      return unless should_comment

      octokit.add_comment(repo_full_name, issue_number, msg)
    end

    def deploy!(strict = false)
      reina = Controller.new(params, strict)

      deploy_finished_message = "Finished deploying.\n"

      reina.apps.map do |app|
        live_url = "[Live url](#{deployed_url(app)}) " if app.show_live_url?
        deploy_finished_message += "\n\
- #{app.name} -- #{live_url}[Heroku](#{heroku_url(app)}) \
[Settings](#{heroku_url(app, "settings")}) \
[Logs](#{heroku_url(app, "logs")})"
      end

      deploy_finished_message += "\n"

      fork do
        apps_count = reina.apps.size

        if apps_count > 1
          post_reply("Starting to deploy #{apps_count} apps...")
        else
          post_reply("Starting to deploy one app...")
        end

        reina.create_netrc if reina.heroku?
        reina.delete_existing_apps!
        reina.deploy_parallel_apps!
        reina.deploy_non_parallel_apps!

        post_reply(deploy_finished_message)
      rescue Controller::DeploymentError => e
        post_reply("Encountered an error with deployment for '#{e.app.name}'")
      rescue Exception => e
        post_reply("Encountered an error with deployment")
      end
    end

    def destroy!
      reina = Controller.new(params)
      return if reina.existing_apps.empty?

      should_comment = config[:oauth_token].present?

      fork do
        reina.create_netrc if reina.heroku?
        reina.delete_existing_apps!

        post_reply('All the staging apps related to this issue have been deleted.')
      end
    end

    def octokit
      return @_octokit if @_octokit.present?

      client = Octokit::Client.new(access_token: config[:oauth_token])
      user = client.user
      user.login
      @_octokit = client
    end

    def params
      return [issue_number] if comment_body.blank?

      extra_params = comment_body
        .lines.first
        &.split(/#{DESTROY_TRIGGER}|#{DEPLOY_TRIGGER}|#{SINGLE_DEPLOY_TRIGGER}/)[1]
        &.split(' ')
        &.reject(&:blank?)

      return [issue_number] unless extra_params.present?

      if destroy_requested?
        begin
          [Integer(extra_params[0])]
        rescue => e
          post_reply("Unable to parse issue number '#{extra_params[0]}'.")
          raise e
        end
      else
        [issue_number, extra_params].flatten
      end
    end

    def signature
      request.env['HTTP_X_HUB_SIGNATURE']
    end

    def event
      request.env['HTTP_X_GITHUB_EVENT']
    end

    def action
      payload['action']
    end

    def issue_number
      payload.dig('issue', 'number') || payload.dig('pull_request', 'number')
    end

    def repo_name
      payload.dig('repository', 'name')
    end

    def repo_full_name
      payload.dig('repository', 'full_name')
    end

    def is_comment?
      event == 'issue_comment' && payload.dig('comment').present?
    end

    def comment_body
      payload.dig('comment', 'body')&.strip.to_s
    end

    def comment_author
      payload.dig('comment', 'user', 'login')
    end

    def payload
      return @_payload if @_payload.present?

      @_payload ||= JSON.parse(raw_payload)
    end

    def raw_payload
      return @_raw_payload if @_raw_payload.present?

      request.body.rewind
      @_raw_payload ||= request.body.read
    end

    def hmac_digest
      @_hmac_digest ||= OpenSSL::Digest.new('sha1')
    end
  end
end
