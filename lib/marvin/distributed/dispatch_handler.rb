require 'rinda/ring'
require 'rinda/tuplespace'

DRb.start_service

module Marvin
  module Distributed
    
    # Handler to provide 
    class DispatchHandler < Marvin::Base
      
      LOOKUP_TIMEOUT = 0.5
      
      # Tell the client that we shouldn't be dumped.
      Marvin::AbstractClient.class_eval { include(DRbUndumped) }
      
      # Get the ring server - if it exists, we will return the current
      # instance other wise it follows a few steps to try and find a new
      # one. Since there can be a delay in getting a response, we'll only
      # check every 5 messages.
      def ring_server
        if @@rs.nil? && (@lookup_attempts ||= 6) > 5
          @lookup_attempts = 0
          @@rs = Rinda::RingFinger.finger.lookup_ring(LOOKUP_TIMEOUT)
          logger.info "Found new ring server => #{@@rs.__drburi}"
        elsif @@rs.nil?
          @lookup_attempts += 1
        end
        return @@rs
      rescue RingNotFound
        @@rs = nil
      end
      
      # Takes an incoming messsage and does all the fancy
      # Stuff with it.
      def handle(message, options)
        return if message == :incoming_line
        super(message, options)
        dispatch(message, options)
      end
      
      # Attempts to add a message to the current tuple space,
      # adding it to a message queue if it can't be added.
      # If there are many items, it will log a warning.
      # TODO: Improve it to dump messages to disk at a predefined limit.
      def dispatch(name, options)
        options[:dispatched_at] ||= Time.now
        tuple = [:marvin_event, Marvin::Settings.distributed_namespace, name, options, self.client]
        begin
          (@queued_messages ||= []) << tuple
          if self.ring_server.nil?
            size = @queued_messages.size
            if size > 0 && size % 25 == 0
              logger.warn "Dispatch handler queue is currently holding #{size} items"
            end
          else
            logger.debug "Writing #{@queued_messages.size} message to the ring server"
            @queued_messages.dup.each do |t|
              ring_server.write(t)
              @queued_messages.delete(t)
            end
          end
        rescue
          # Reset the ring finger to the next choice.
          logger.debug "Ring server unavailable, resetting..."
          @@rs = nil
        end
      end
      
      # Register this as a handler, but only if we're
      # running in "client mode" - in other words, we
      # want to make sure it won't start up an infinite
      # loop.
      def self.register!(*args)
        # DO NOT register if this is not a normal client.
        return unless Marvin::Loader.type == :client
        super
      end
      
    end
  end
end