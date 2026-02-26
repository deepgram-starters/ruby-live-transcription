# Puma configuration for Ruby Live Transcription Starter
#
# Puma is required for faye-websocket support (Rack hijack).
# Single-threaded to keep WebSocket forwarding simple and predictable.

bind "tcp://#{ENV.fetch('HOST', '0.0.0.0')}:#{ENV.fetch('PORT', '8081')}"

workers 0
threads 1, 5

environment ENV.fetch('RACK_ENV', 'production')

# Quiet startup (Sinatra/Puma banner handled in app output)
quiet
