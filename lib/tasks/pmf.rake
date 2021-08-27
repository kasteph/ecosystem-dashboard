namespace :pmf do
  task states: :environment do
    start_date = 6.week.ago
    end_date = 2.week.ago
    window = 7

    windows = Pmf.states_summary(start_date, end_date, window)
    windows.each do |window|
      puts window[:date]

      window[:states].each do |state, users|
        puts "  #{state} (#{users})"
      end

      puts
    end
  end

  task transitions: :environment do
    start_date = 6.week.ago
    end_date = 2.week.ago
    window = 7

    windows = Pmf.transitions(start_date, end_date, window)
    windows.each do |window|
      puts window[:date]

      window[:transitions].each do |transition, users|
        puts "  #{transition} (#{users})"
      end

      puts
    end
  end

  task warm_caches: :environment do
    # run this via cron just after midnight
    # calculate pmf windows for past year from yesterday
    end_date = Date.yesterday - 3
    start_date = Date.parse('2020-11-20')

    host = "#{ENV['DISPLAY_NAME'].downcase}.ecosystem-dashboard.com"

    paths = [
      "/pmf/repo/transitions.json?start_date=2020-11-20",
      "/pmf/repo/states.json?start_date=2020-11-20"
    ]

    if ENV['DISPLAY_NAME'] == 'IPFS'
      paths += [
        "/pmf/repo/combined/states.json?start_date=2020-11-20",
        "/pmf/repo/combined/transitions.json?start_date=2020-11-20"
      ]
    end

    [7,14,30,90].each do |window|
      puts [start_date, end_date, window].join('-')
      transitions = PmfRepo.transitions(start_date, end_date, window)
      puts "  #{transitions.length} transitions"
      states = PmfRepo.states(start_date, end_date, window)
      puts "  #{states.length} states"
    end

    paths.each do |path|
      Faraday.get("https://#{host}#{path}")
    end
  end
end
