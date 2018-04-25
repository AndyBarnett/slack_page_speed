require 'httparty'
require 'json'
require 'yaml'

def configure
  puts "hi"
end


configuration_info = YAML.load_file('configuration.yml')
@slack_post_url    = configuration_info['slack_url']

HTTParty::Basement.default_options.update(verify: false)
@pagespeed_api_key    = configuration_info['pagespeed_api_key']
@webpagetest_api_key  = configuration_info['webpagetest_api_key']
@slack_post_url       = configuration_info['slack_url']
@history_file         = './pagespeed_history.txt'
@slack_channel        = configuration_info['slack_channel']
@slack_username       = configuration_info['slack_username']
@slack_bot_emoji      = configuration_info['slack_bot_emoji']
@improvement_emoji    = configuration_info['improvement_emoji']
@minimal_change_emoji = configuration_info['minimal_change_emoji']
@regression_emoji     = configuration_info['regression_emoji']
@domain               = configuration_info['domain']
@message              = configuration_info['include_timestamp'] ? "Page performance scores for #{Date.today.strftime('%d/%m/%Y')}. \n" : ''
@threshold            = configuration_info['threshold'].to_i
@results              = {}
# @page_list            = %w(
#   credit-cards/
#   life-insurance/
#   energy/
#   home-insurance/
#   travel-insurance/
#   car-insurance/
#   Homepage
# )
@page_list            = configuration_info['page_list']

# @run_results = [{}, {}, {}]
@run_results          = [{}]
@page_list.each do |page|
  search_string  = page.gsub('-', '+').gsub('/', '')
  search_string  = search_string + '+switch' if page == 'energy/'
  search_string  = 'compare+the+market' if page == 'Homepage'
  @results[page] = { search_string: search_string }
  @run_results.each do |run_result|
    run_result[page] = { search_string: search_string }
  end
end

# Gets google page rank
def get_gpr(page, search_string, iteration)
  puts page
  response = JSON.parse(HTTParty.get("https://www.googleapis.com/customsearch/v1element?key=#{@pagespeed_api_key}&rsz=filtered_cse&num=10&hl=en&prettyPrint=false&source=gcsc&gss=.com&q=#{search_string}&sort=&googlehost=www.google.co.uk&oq=#{search_string}&gs_l=partner.12...31030.31885.0.34635.7.7.0.0.0.0.73.428.7.7.0.gsnos%2Cn%3D13...0.864j151518j7..1ac.1.25.partner..7.0.0.-WiGDitO8Y8&callback=google.search.Search.apiary19818&nocache=1502961217931").body.chomp[49..-3])
  begin
    @run_results[iteration][page][:rank] = response['results'].index { |result_property| result_property['url'].include? 'comparethemarket.com' } + 1
  rescue NoMethodError => e
    puts "Not on the front page of Google results for '#{page}'.\nResults were: \n"
    response['results'].each { |result| puts result['url'] }
    raise e
  end
end

# Gets google pagespeed score for a 'page'
def get_gps_score(page, strategy, iteration)
  response = HTTParty.get("https://www.googleapis.com/pagespeedonline/v2/runPagespeed?url=#{@domain + page.gsub('Homepage', '') + '?src=TSTT'}&strategy=#{strategy}&key=#{@pagespeed_api_key}")
  unless response.response.code == '200' && JSON.parse(response.body)['responseCode'] != '400'
    puts response
    raise "Couldn't get Google PageSpeed score for #{page}"
  end
  score                                          = JSON.parse(response.body)['ruleGroups']['SPEED']['score']
  @run_results[iteration][page][strategy.to_sym] = score
end

# runs a new WebPageTest test based on the url supplied
def start_wpt_test(page, iteration)
  response = HTTParty.get("http://www.webpagetest.org/runtest.php?url=#{@domain + page.gsub('Homepage', '') + '?src=TSTT'}&location=Dulles.3G&f=json&fvonly=1&k=#{@webpagetest_api_key}")
  raise "Couldn't get WebPageTest score for #{page}" unless response.response.code == '200'
  @run_results[iteration][page][:results_url] = JSON.parse(response.body)['data']['jsonUrl']
end

# waits until the status of the run at 'results_url' is 200 (test finished)
def wait_for_wpt_results(page, result_url, iteration)
  361.times do
    @response = HTTParty.get(result_url)
    puts "#{JSON.parse(@response.body)['statusText']} for #{page}"
    break if JSON.parse(@response.body)['statusCode'] == 200
    sleep 10
  end
  @run_results[iteration][page][:speed_index] = (JSON.parse(@response.body)['data']['runs']['1']['firstView']['SpeedIndex'].to_f / 1000).round(2)
end

# Send a slack message with all the scores
def slack_notify(message)
  HTTParty.post(@slack_post_url,
                body:    { 'channel': "##{@slack_channel}", 'icon_emoji': @slack_bot_emoji, 'username': @slack_username, 'text': message }.to_json,
                headers: { 'Content-Type': 'application/json',
                           'Accept':       'application/json' })
end

def get_old_score(latest_score, page, score_key)
  threshold          = score_key == :rank ? 0 : @threshold
  comparison_message = ''
  if File.exist?(@history_file) && JSON.parse(File.read(@history_file)).keys.include?(page)
    # We want the pagespeed score to be greater than before,
    # but we want the speed index to be less than.
    compare_operator   = (score_key == :speed_index || score_key == :rank) ? :> : :<
    # Open file that stores the history of the latest scores
    file               = File.open(@history_file, 'r')
    # Find the value of the score of the page we want
    old_score          = JSON.parse(file.read)[page][score_key.to_s]
    # Check if it's within the acceptable threshold, otherwise,
    # check if it's greater than or less than (depending on what type of score it is)
    # and add the relevant emoji
    comparison_message = " (was #{old_score})"
    if latest_score.to_f.between?(old_score.to_f - threshold, old_score.to_f + threshold)
      comparison_message += " #{@minimal_change_emoji}"
    elsif latest_score.to_f.send(compare_operator, old_score.to_f)
      comparison_message += " #{@regression_emoji}"
    else
      comparison_message += " #{@improvement_emoji}"
    end
  end
  comparison_message
end

def write_new_scores
  file = File.open(@history_file, 'w+')

  # Clear the file
  file.truncate(0)
  file.write(@results.to_json)
  file.close
end

# ==========
# RUN SCRIPT
# ==========

# This kicks off a WebPageTest test for every page in the '@page_list' array
@page_list.each do |page|
  @run_results.length.times do |iteration|
    start_wpt_test(page, iteration)
    # get_gpr(page, @results[page][:search_string], iteration)
  end
end

# Waiting for WebPageTest results and storing them
@page_list.reverse_each do |page|
  # This collates the results after all tests have finished
  @run_results.length.times do |iteration|
    wait_for_wpt_results(page, @run_results[iteration][page][:results_url], iteration)
  end

  # Average all the GPS scores
  @run_results.length.times do |iteration|
    get_gps_score(page, 'desktop', iteration)
    get_gps_score(page, 'mobile', iteration)
  end

  # Reset the temporary results array
  # @results[page][:rank]        = []
  @results[page][:speed_index] = []
  @results[page][:desktop]     = []
  @results[page][:mobile]      = []

  # Add all results to an array of results for each numerical result type
  @run_results.each do |result|
    # @results[page][:rank].push(result[page][:rank])
    @results[page][:speed_index].push(result[page][:speed_index])
    @results[page][:desktop].push(result[page][:desktop])
    @results[page][:mobile].push(result[page][:mobile])
  end

  # Calculate the mean speed, desktop and mobile scores, and the mode search ranking
  # @results[page][:rank]        = @results[page][:rank].max_by { |i| @results[page][:rank].count(i) }
  @results[page][:desktop]     = @results[page][:desktop].max_by { |i| @results[page][:desktop].count(i) }
  @results[page][:mobile]      = @results[page][:mobile].max_by { |i| @results[page][:mobile].count(i) }
  @results[page][:speed_index] = (@results[page][:speed_index].inject(:+)/@run_results.length).round(2)

  # Build the slack message
  puts @results if ENV['logging'] == 'true'
  @message += "\n*" + page + ':*'
  @message += "\n     desktop score: " + @results[page][:desktop].to_s
  @message += get_old_score(@results[page][:desktop], page, :desktop)
  @message += "\n     mobile score: " + @results[page][:mobile].to_s
  @message += get_old_score(@results[page][:mobile], page, :mobile)
  @message += "\n     SpeedIndex: " + @results[page][:speed_index].to_s
  @message += get_old_score(@results[page][:speed_index].to_f, page, :speed_index) + "\n"
  # @message += "\n     Google Search Rank: " + @results[page][:rank].to_s
  # @message += get_old_score(@results[page][:rank].to_f, page, :rank) + "\n"
end

# Add an '@here' to the slack notification if any score has regressed
@message += ' <!here> Something is worse than last time!' if @message.include?(@regression_emoji)
puts @message
slack_notify(@message)
# Create the scores history file if this is the first run
File.new(@history_file, 'w') unless File.exist?(@history_file)
write_new_scores
