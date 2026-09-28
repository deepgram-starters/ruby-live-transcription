ENV['DEEPGRAM_API_KEY'] = 'test-key'

require 'uri'
require_relative '../app'

def query_for(params)
  URI.decode_www_form(URI.parse(build_deepgram_url(params)).query).to_h
end

default_value = query_for({})['interim_results']
raise "expected interim_results=false by default, got #{default_value.inspect}" unless default_value == 'false'

explicit_value = query_for('interim_results' => 'false')['interim_results']
raise "expected explicit interim_results=false, got #{explicit_value.inspect}" unless explicit_value == 'false'

binary_audio = "\x00\x01".b
raise 'expected binary audio to be forwarded as bytes' unless websocket_frame(binary_audio) == [0, 1]
raise 'expected text frames to remain strings' unless websocket_frame('{"type":"CloseStream"}').is_a?(String)
raise 'expected unsupported upstream close to map to 1000' unless browser_close_code(1006) == 1000
raise 'expected reserved upstream close to map to 1000' unless browser_close_code(1011) == 1000
raise 'expected normal upstream close to be preserved' unless browser_close_code(1000) == 1000
