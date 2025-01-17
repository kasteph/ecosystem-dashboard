class Event < ApplicationRecord

  belongs_to :repository, optional: true
  belongs_to :contributor, foreign_key: :actor, primary_key: :github_username, optional: true
  belongs_to :organization, foreign_key: :org, primary_key: :name, optional: true

  scope :internal, -> { where(org: Organization.internal_org_names) }
  scope :external, -> { where.not(org: Organization.internal_org_names) }
  scope :org, ->(org) { where(org: org) }
  scope :user, ->(user) { where(actor: user)}
  scope :repo, ->(repository_full_name) { where(repository_full_name: repository_full_name)}
  scope :event_type, ->(event_type) { where(event_type: event_type) }

  scope :humans, -> { where(bot: [false, nil]) }
  scope :bots, -> { where(bot: true) }
  scope :core, -> { where(core: true) }
  scope :not_core, -> { where(core: [false, nil]) }

  scope :this_period, ->(period) { where('events.created_at > ?', period.days.ago) }
  scope :last_period, ->(period) { where('events.created_at > ?', (period*2).days.ago).where('events.created_at < ?', period.days.ago) }
  scope :this_week, -> { where('events.created_at > ?', 1.week.ago) }
  scope :last_week, -> { where('events.created_at > ?', 2.week.ago).where('events.created_at < ?', 1.week.ago) }

  scope :created_before, ->(datetime) { where('events.created_at < ?', datetime) }
  scope :created_after, ->(datetime) { where('events.created_at > ?', datetime) }
  scope :created_before_date, ->(date) { where('date(events.created_at) < ?', date) }
  scope :created_after_date, ->(date) { where('date(events.created_at) > ?', date) }

  scope :search, ->(query) { where('payload::text ilike ?', "%#{query}%") }

  scope :not_stars, -> { where.not(event_type: 'WatchEvent') }
  scope :not_forks, -> { where.not(event_type: 'ForkEvent') }

  def contributed?
    return true unless contributor.present?
    !contributor.core?
  end

  def self.set_pmf_field
    Event.humans.not_core.where.not(event_type: ['WatchEvent', 'MemberEvent', 'PublicEvent']).where(pmf: nil).in_batches(of: 1000).update_all(pmf: true)
  end

  def self.update_core_events
    Contributor.core.pluck(:github_username).each do |username|
      Event.where(actor: username).update_all(core: true)
    end
  end

  def self.update_bot_events
    Contributor.bot.pluck(:github_username).each do |username|
      Event.where(actor: username).update_all(bot: true)
    end
  end

  def self.record_event(repository, event_json, contributor = nil)
    begin
      e = Event.find_or_initialize_by(github_id: event_json['id'])

      e.actor = event_json['actor']['login']
      e.event_type = event_json['type']
      e.action = event_json['payload']['action']
      if e.repository_id.nil?
        repository ||= Repository.find_by_full_name(event_json['repo']['name'])
        e.repository_id = repository.try(:id)
        e.repository_full_name = repository.try(:full_name) || event_json['repo']['name']
        e.org = repository.try(:org) || event_json['repo']['name'].split('/')[0]
      end
      e.payload = event_json['payload'].to_h
      e.created_at = event_json['created_at']
      if e.core.nil?
        contributor ||= Contributor.find_by(github_username: e.actor)
        e.core = contributor.try(:core)
      end
      if e.bot.nil?
        contributor ||= Contributor.find_by(github_username: e.actor)
        e.bot = contributor.try(:bot)
      end
      if !['WatchEvent', 'MemberEvent', 'PublicEvent'].include?(e.event_type)
        if e.core && !e.bot
          e.pmf = true
        end
      end
      e.save if e.changed?
    rescue ActiveRecord::StatementInvalid
      # garbage data, ignore it
    end
  end

  def title
    "#{actor} #{action_text} #{repository.full_name}"
  end

  def html_url
    case event_type
    when 'WatchEvent'
      "https://github.com/#{repository.full_name}/stargazers"
    when "CreateEvent"
      "https://github.com/#{repository.full_name}/tree/#{payload['ref']}"
    when "CommitCommentEvent"
      payload['comment']['html_url']
    when "ReleaseEvent"
      payload['release']['html_url']
    when "IssuesEvent"
      payload['issue']['html_url']
    when "DeleteEvent"
      "https://github.com/#{repository.full_name}"
    when "IssueCommentEvent"
      payload['comment']['html_url']
    when "PublicEvent"
      "https://github.com/#{repository.full_name}"
    when "PushEvent"
      "https://github.com/#{repository.full_name}/commits/#{payload['ref'].gsub("refs/heads/", '')}"
    when "PullRequestReviewCommentEvent"
      payload['comment']['html_url']
    when "PullRequestReviewEvent"
      payload['review']['html_url']
    when "PullRequestEvent"
      payload['pull_request']['html_url']
    when "ForkEvent"
      payload['forkee']['html_url']
    when 'MemberEvent'
      "https://github.com/#{payload['member']['login']}"
    when 'GollumEvent'
      payload['pages'].first['html_url']
    end
  end

  def action_text
    case event_type
    when 'WatchEvent'
      'starred'
    when "CreateEvent"
      "created a #{payload['ref_type']} on"
    when "CommitCommentEvent"
      'commented on a commit on'
    when "ReleaseEvent"
      "#{action} a release on"
    when "IssuesEvent"
      "#{action} an issue on"
    when "DeleteEvent"
      "deleted a #{payload['ref_type']}"
    when "IssueCommentEvent"
      if payload['issue']['pull_request'].present?
        "#{action} a comment on a pull request on"
      else
        "#{action} a comment on an issue on"
      end
    when "PublicEvent"
      'open sourced'
    when "PushEvent"
      "pushed #{ActionController::Base.helpers.pluralize(payload['size'], 'commit')} to #{payload['ref'].gsub("refs/heads/", '')}"
    when "PullRequestReviewCommentEvent"
      "#{action} a review comment on an pull request on"
    when "PullRequestReviewEvent"
      "#{action} a review on an pull request on"
    when "PullRequestEvent"
      "#{action} an pull request on"
    when "ForkEvent"
      'forked'
    when 'MemberEvent'
      "#{action} #{payload['member']['login']} to"
    when 'GollumEvent'
      "#{payload['pages'].first['action']} a wiki page on"
    end
  end

  def breaking?
    return false unless event_type == 'ReleaseEvent'
    payload['release']['body'].downcase.match?(/##(.)+breaking/i)
  end
end
