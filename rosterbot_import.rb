require 'bundler'
require 'active_support/all'
require 'csv'
require 'selenium/webdriver'
require 'browsermob/proxy'
require 'byebug'
Bundler.require

# Get environment
test = ARGV[0].try(:strip) == 'test'

CONFIG = YAML.load(File.read('config.yml'))
EVENT_PAYLOAD =  YAML.load(File.read('rosterbot.yml'))

TEST_TEAM_ID = CONFIG['TEST_TEAM_ID']
TEAM_ID = CONFIG['TEAM_ID']
TEAM_NAME = CONFIG['TEAM_NAME']

LOGIN_URL='https://app.rosterbot.com/login'
EVENT_ENDPOINT="https://api.rosterbot.com/api/v1/teams/#{test ? TEST_TEAM_ID : TEAM_ID}/events"
APP_TEAM_URL = "https://app.rosterbot.com/teams/#{test ? TEST_TEAM_ID : TEAM_ID}"
SPREADSHEET_URL = CONFIG['SPREADSHEET_URL']

### METHODS ####

def getToken
  server = BrowserMob::Proxy::Server.new("#{Dir.pwd}/tools/browsermob-proxy/bin/browsermob-proxy") #=> #<BrowserMob::Proxy::Server:0x000001022c6ea8 ...>
  server.start

  proxy = server.create_proxy #=> #<BrowserMob::Proxy::Client:0x0000010224bdc0 ...>

  # WebDriver setup
  caps = Selenium::WebDriver::Remote::Capabilities.chrome(:proxy => proxy.selenium_proxy(:ssl))
  driver = Selenium::WebDriver.for(:chrome, :desired_capabilities => caps)

  # Navigate to login url and populate user credentials, submit form
  driver.navigate.to LOGIN_URL
  user_credentials = YAML.load(File.read('user_credentials.yml'))
  driver.find_element(:name, 'email').send_keys(user_credentials['username'] || ENV['ROSTERBOT_USERNAME'])
  driver.find_element(:name, 'password').send_keys(user_credentials['password'] || ENV['ROSTERBOT_PASSWORD'])
  driver.find_element(:css, "div.entrance-content > button").click

  # Wait for login step to complete
  wait = Selenium::WebDriver::Wait.new(:timeout => 60)
  wait.until {
    sleep(2)
    #driver.find_element(:css, "div.home-header")
  }

  # Capture network traffic
  proxy.new_har('rosterbot',:capture_headers => true)

  driver.navigate.to APP_TEAM_URL

  # Parse back Authorization bearer token (suck it, Rosterbot!)
  token = proxy.har.entries.map { |e| e.request.headers }.flatten.find { |h| h['name'] == 'Authorization'}['value']

  proxy.close
  driver.quit

  token
end

def getScore(event, bearer)
  response = RestClient.get "#{EVENT_ENDPOINT}/#{event['id']}/score", {'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': bearer}
  JSON.parse(response.body)['ok']
end

def updateScore(event, bearer, your_score, their_score, outcome)
  payload = {'outcome' => outcome, 'score_value '=> nil, 'your_score' => your_score, 'their_score' => their_score}.to_json
  RestClient.post "#{EVENT_ENDPOINT}/#{event['id']}/score", payload, {'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': bearer}
end


def eventExists?(title, start_time, end_time, events)
  events.find { |e| e['title'] == title && (DateTime.parse(e['start_time']) == DateTime.parse(start_time)) && (DateTime.parse(e['end_time']) == DateTime.parse(end_time)) }
end

def getEvents(bearer)
  response = RestClient.get EVENT_ENDPOINT, {'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': bearer}
  JSON.parse(response.body)['ok']
end

def createEvent(title, start_time, end_time, payload, bearer)
  json = payload.merge(:start_time => start_time, :end_time => end_time, :title => title).to_json
  RestClient.post  EVENT_ENDPOINT, json , {'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': bearer}
end


def getGames(worksheet)
  # Games array and date
  games, date, tz = [], '', TZInfo::Timezone.get('US/Pacific')
  worksheet.rows.each { |row|
    begin
      checkDate = Regexp.new('[0-9]{1,2}\/[0-9]{1,2}').match(row[0])
      date = checkDate[0] unless checkDate.nil?
      game = row.each_index.select{|i| ![row[i]].grep(/#{TEAM_NAME} v\.?/).empty? || ![row[i]].grep(/v\.? #{TEAM_NAME}/).empty? }

      next if game.empty?
      timeWithZone = tz.local_to_utc(Time.parse(Date.parse(date).to_s + ' ' + row[game.first-1].to_s +  ' PST/PDT'))
      startTime = DateTime.parse(timeWithZone.to_s)
      # Handle end of year edge-case 
      timeNow = DateTime.now
      if ((timeNow.strftime("%m").to_i - startTime.strftime("%m").to_i).abs > 2 )
        startTime += 1.year
      end  
      endTime = startTime + 1.hour

      # Winner column
      outcome = row[game.first + 1].include?(TEAM_NAME) ? 'Win' : 'Loss'
      score, opponent_score = 0, 0
      result = row[game.first + 2]
      loser_score, winner_score = *result.split('-').minmax
      if outcome == 'Win'
        score, opponent_score = winner_score, loser_score
      else
        score, opponent_score = loser_score, winner_score
      end

      puts "Start Time: #{startTime.strftime('%FT%T.000Z')}, End Time: #{endTime.strftime('%FT%T.000Z')}, Game: #{row[game.first]}, Outcome: #{outcome}, Score: #{score}, Opponent Score: #{opponent_score}"
      games.push({'start_time' => startTime.strftime('%FT%T.000Z'), 'end_time' => endTime.strftime('%FT%T.000Z'), 'title' => row[game.first], 'outcome' => outcome, 'your_score' => score, 'their_score' => opponent_score })
    rescue ArgumentError => e
    end
  }
  games
end

def upsertEvents(games)
  # Bearer token
  bearer = getToken

  events = getEvents(bearer)
  games.each do |game|
    begin
      event = eventExists?(game['title'], game['start_time'], game['end_time'], events)
      if event
        puts "Event #{game['title']} exists already!\n"
        score = getScore(event, bearer) rescue {}
        if !game['outcome'].empty? && ((score['your_score'].to_i != game['your_score'].to_i) && (score['their_score'].to_i != game['their_score'].to_i))
          puts "Updating score for game #{game['title']}"
          updateScore(event, bearer, game['your_score'], game['their_score'], game['outcome'])
        end
      else
        puts "Event not yet created. Calling rosterbot event endpoint create\n"
        createEvent(game['title'], game['start_time'], game['end_time'], EVENT_PAYLOAD, bearer)
      end
    rescue RestClient::InternalServerError=> e
      puts "Encountered an issue while GETing/POSTing to Rosterbot\n"
      puts e.backtrace
    end
  end
end


### MAIN ###

#Authenticate a session with your Service Account
session = GoogleDrive::Session.from_service_account_key('client_secret.json')
# Get the spreadsheet by its title
spreadsheet = session.spreadsheet_by_url(SPREADSHEET_URL)
# Get the first worksheet
worksheet = spreadsheet.worksheets.first

games = getGames(worksheet)
upsertEvents(games)
