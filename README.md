## Usage
# Setup
Run `slack_page_speed configure` and a 'configuration.yml' file should be created.
Fill out the desired values for all the properties in this file. You MUST fill in the following values yourself as a minimum for this gem to work:
* slack_url
* pagespeed_api_key
* webpagetest_api_key
* slack_channel
* domain
* page_list

# Running
You should run the script in a directory that will be dedicated to Pagespeed scores, because for this gem to be the most useful it can be, it relies on keeping a history file of scores from the previous run.

Run `slack_page_speed` (Can only be done after Setup!)