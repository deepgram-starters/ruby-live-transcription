# Ruby Live Transcription Starter - Backend Server
#
# Simple WebSocket proxy to Deepgram's Live Transcription API.
# Forwards all messages (JSON and binary) bidirectionally between client and Deepgram.
#
# Routes:
#   GET  /api/session              - Issue JWT session token
#   GET  /api/metadata             - Project metadata from deepgram.toml
#   WS   /api/live-transcription   - WebSocket proxy to Deepgram STT (auth required)
#   GET  /health                   - Health check

require 'sinatra/base'
require 'sinatra/cross_origin'
require 'json'
require 'securerandom'
require 'jwt'
require 'toml-rb'
require 'dotenv/load'
require 'faye/websocket'
require 'uri'

# ============================================================================
# CONFIGURATION
# ============================================================================

DEEPGRAM_API_KEY = ENV['DEEPGRAM_API_KEY']

unless DEEPGRAM_API_KEY && !DEEPGRAM_API_KEY.empty?
  $stderr.puts 'ERROR: DEEPGRAM_API_KEY environment variable is required'
  $stderr.puts 'Please copy sample.env to .env and add your API key'
  exit 1
end

DEEPGRAM_STT_URL = 'wss://api.deepgram.com/v1/listen'
PORT = (ENV['PORT'] || '8081').to_i
HOST = ENV['HOST'] || '0.0.0.0'
SESSION_SECRET = ENV['SESSION_SECRET'] || SecureRandom.hex(32)
JWT_EXPIRY = 3600 # 1 hour in seconds

# ============================================================================
# SESSION AUTH - JWT tokens for production security
# ============================================================================

# Issues a signed JWT with a 1-hour expiry.
def issue_token
  payload = {
    iat: Time.now.to_i,
    exp: Time.now.to_i + JWT_EXPIRY
  }
  JWT.encode(payload, SESSION_SECRET, 'HS256')
end

# Validates a JWT token string. Returns true if valid, false otherwise.
def validate_token(token_str)
  JWT.decode(token_str, SESSION_SECRET, true, algorithm: 'HS256')
  true
rescue JWT::DecodeError
  false
end

# Extracts and validates a JWT from the access_token.<jwt> subprotocol.
# Returns the full subprotocol string if valid, nil if invalid.
def validate_ws_token(protocols)
  return nil unless protocols

  protocol_list = protocols.is_a?(Array) ? protocols : protocols.split(',').map(&:strip)
  protocol_list.each do |proto|
    if proto.start_with?('access_token.')
      token_str = proto.sub('access_token.', '')
      return proto if validate_token(token_str)
    end
  end
  nil
end

# ============================================================================
# DEEPGRAM URL BUILDER
# ============================================================================

# Constructs the Deepgram WebSocket URL with query parameters forwarded
# from the client request.
def build_deepgram_url(request_params)
  uri = URI.parse(DEEPGRAM_STT_URL)

  # Map of parameter names to defaults
  params = {
    'model'        => 'nova-3',
    'language'     => 'en',
    'smart_format' => 'true',
    'punctuate'    => 'true',
    'diarize'      => 'false',
    'filler_words' => 'false',
    'encoding'     => 'linear16',
    'sample_rate'  => '16000',
    'channels'     => '1'
  }

  query_parts = params.map do |name, default_val|
    val = request_params[name] || default_val
    "#{URI.encode_www_form_component(name)}=#{URI.encode_www_form_component(val)}"
  end

  uri.query = query_parts.join('&')
  uri.to_s
end

# ============================================================================
# WEBSOCKET MIDDLEWARE - Handles WS upgrades before Sinatra routes
# ============================================================================

class WebSocketMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    if Faye::WebSocket.websocket?(env) && env['PATH_INFO'] == '/api/live-transcription'
      handle_live_transcription(env)
    else
      @app.call(env)
    end
  end

  private

  # Handles the /api/live-transcription WebSocket endpoint.
  # Authenticates via JWT subprotocol, then creates a bidirectional proxy to Deepgram.
  def handle_live_transcription(env)
    puts 'WebSocket upgrade request for: /api/live-transcription'

    # Extract subprotocols from the Sec-WebSocket-Protocol header
    protocols_header = env['HTTP_SEC_WEBSOCKET_PROTOCOL']
    protocols = protocols_header ? protocols_header.split(',').map(&:strip) : []

    # Validate JWT from access_token.<jwt> subprotocol
    valid_proto = validate_ws_token(protocols)
    unless valid_proto
      puts 'WebSocket auth failed: invalid or missing token'
      return [401, { 'Content-Type' => 'text/plain' }, ['Unauthorized']]
    end

    puts 'Backend handling /api/live-transcription WebSocket (authenticated)'

    # Accept the WebSocket connection, echoing back the validated subprotocol
    ws = Faye::WebSocket.new(env, [valid_proto])

    # Parse query parameters from the request
    request = Rack::Request.new(env)
    query_params = request.params

    model       = query_params['model']       || 'nova-3'
    language    = query_params['language']     || 'en'
    encoding    = query_params['encoding']     || 'linear16'
    sample_rate = query_params['sample_rate']  || '16000'
    channels    = query_params['channels']     || '1'

    puts "Connecting to Deepgram STT: model=#{model}, language=#{language}, " \
         "encoding=#{encoding}, sample_rate=#{sample_rate}, channels=#{channels}"

    # Build Deepgram URL with forwarded query parameters
    deepgram_url = build_deepgram_url(query_params)

    # Connect to Deepgram with API key auth
    deepgram_ws = Faye::WebSocket::Client.new(deepgram_url, nil,
      headers: { 'Authorization' => "Token #{DEEPGRAM_API_KEY}" }
    )

    client_msg_count = 0
    deepgram_msg_count = 0

    # ---- Deepgram connection events ----

    deepgram_ws.on :open do |_event|
      puts 'Connected to Deepgram STT API'
    end

    # Forward Deepgram messages to client
    deepgram_ws.on :message do |event|
      deepgram_msg_count += 1
      is_binary = event.data.is_a?(Array)
      if deepgram_msg_count % 10 == 0 || !is_binary
        data_size = is_binary ? event.data.length : event.data.bytesize
        puts "Deepgram message ##{deepgram_msg_count} (binary: #{is_binary}, size: #{data_size})"
      end
      ws.send(event.data) if ws
    end

    deepgram_ws.on :error do |event|
      puts "Deepgram WebSocket error: #{event.message}"
      ws.close(1011, 'Deepgram connection error') if ws
    end

    deepgram_ws.on :close do |event|
      puts "Deepgram connection closed: #{event.code} #{event.reason}"
      ws.close(event.code, event.reason) if ws
      deepgram_ws = nil
    end

    # ---- Client connection events ----

    ws.on :open do |_event|
      puts 'Client connected to /api/live-transcription'
    end

    # Forward client messages to Deepgram
    ws.on :message do |event|
      client_msg_count += 1
      is_binary = event.data.is_a?(Array)
      if client_msg_count % 100 == 0 || !is_binary
        data_size = is_binary ? event.data.length : event.data.bytesize
        puts "Client message ##{client_msg_count} (binary: #{is_binary}, size: #{data_size})"
      end
      deepgram_ws.send(event.data) if deepgram_ws
    end

    ws.on :error do |event|
      puts "Client WebSocket error: #{event.message}"
      deepgram_ws.close(1011, 'Client error') if deepgram_ws
    end

    ws.on :close do |event|
      puts "Client disconnected: #{event.code} #{event.reason}"
      deepgram_ws.close(1000, 'Client disconnected') if deepgram_ws
      deepgram_ws = nil
      ws = nil
    end

    # Return the WebSocket rack response (hands off to Puma's hijack)
    ws.rack_response
  end
end

# ============================================================================
# SINATRA APP - HTTP routes
# ============================================================================

class App < Sinatra::Base
  register Sinatra::CrossOrigin

  configure do
    enable :cross_origin
  end

  before do
    response.headers['Access-Control-Allow-Origin'] = '*'
  end

  # Handle CORS preflight
  options '*' do
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    200
  end

  # GET /api/session - Issues a signed JWT for session authentication.
  get '/api/session' do
    content_type :json
    begin
      token = issue_token
      { token: token }.to_json
    rescue StandardError => e
      puts "Failed to issue token: #{e.message}"
      status 500
      { error: 'INTERNAL_SERVER_ERROR', message: 'Failed to issue session token' }.to_json
    end
  end

  # GET /api/metadata - Returns the [meta] section from deepgram.toml.
  get '/api/metadata' do
    content_type :json
    begin
      toml_path = File.join(File.dirname(__FILE__), 'deepgram.toml')
      config = TomlRB.load_file(toml_path)

      unless config['meta']
        status 500
        return { error: 'INTERNAL_SERVER_ERROR',
                 message: 'Missing [meta] section in deepgram.toml' }.to_json
      end

      config['meta'].to_json
    rescue StandardError => e
      puts "Error reading metadata: #{e.message}"
      status 500
      { error: 'INTERNAL_SERVER_ERROR',
        message: 'Failed to read metadata from deepgram.toml' }.to_json
    end
  end

  # GET /health - Health check endpoint.
  get '/health' do
    content_type :json
    { status: 'ok' }.to_json
  end
end
