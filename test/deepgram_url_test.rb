ENV['DEEPGRAM_API_KEY'] = 'test-key'

require 'uri'
require_relative '../app'

def query_for(params)
  URI.decode_www_form(URI.parse(build_deepgram_url(params)).query).to_h
end

default_value = query_for({})['interim_results']
raise "expected interim_results=true by default, got #{default_value.inspect}" unless default_value == 'true'

explicit_value = query_for('interim_results' => 'false')['interim_results']
raise "expected explicit interim_results=false, got #{explicit_value.inspect}" unless explicit_value == 'false'
