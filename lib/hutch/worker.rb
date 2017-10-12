require 'hutch/message'
require 'hutch/logging'
require 'hutch/broker'
require 'hutch/acknowledgements/nack_on_all_failures'
require 'hutch/waiter'
require 'carrot-top'
require 'securerandom'

module Hutch
  class ErrorDispatcher
    def initialize(config)
      @config = config
    end

    def handle(*args)
      handlers.each do |backend|
        backend.handle(*args)
      end
    end

    private
    def handlers
      @config[:error_handlers]
    end
  end

  class Worker
    include Logging

    def initialize(broker, consumers, setup_procs)
      @broker        = broker
      self.consumers = consumers
      self.setup_procs = setup_procs
    end

    # Run the main event loop. The consumers will be set up with queues, and
    # process the messages in their respective queues indefinitely. This method
    # never returns.
    def run
      setup_queues
      setup_procs.each(&:call)

      Waiter.wait_until_signaled

      stop
    end

    # Stop a running worker by killing all subscriber threads.
    def stop
      @broker.stop
    end

    # Set up the queues for each of the worker's consumers.
    def setup_queues
      logger.info 'setting up queues'
      @consumers.each { |consumer| setup_queue(consumer) }
    end

    # Bind a consumer's routing keys to its queue, and set up a subscription to
    # receive messages sent to the queue.
    def setup_queue(consumer)
      queue = @broker.queue(consumer.get_queue_name, consumer.get_arguments)
      @broker.bind_queue(queue, consumer.routing_keys)

      queue.subscribe(consumer_tag: unique_consumer_tag, manual_ack: true) do |*args|
        delivery_info, properties, payload = Hutch::Adapter.decode_message(*args)
        handle_message(consumer, delivery_info, properties, payload)
      end
    end

    # Called internally when a new messages comes in from RabbitMQ. Responsible
    # for wrapping up the message and passing it to the consumer.
    def handle_message(consumer, delivery_info, properties, payload)
      serializer = consumer.get_serializer || Hutch::Config[:serializer]
      logger.debug {
        spec   = serializer.binary? ? "#{payload.bytesize} bytes" : "#{payload}"
        "message(#{properties.message_id || '-'}): " +
        "routing key: #{delivery_info.routing_key}, " +
        "consumer: #{consumer}, " +
        "payload: #{spec}"
      }

      message = Message.new(delivery_info, properties, payload, serializer)
      consumer_instance = consumer.new.tap { |c| c.broker, c.delivery_info = @broker, delivery_info }
      with_tracing(consumer_instance).handle(message)
      @broker.ack(delivery_info.delivery_tag)
    rescue => ex
      acknowledge_error(delivery_info, properties, @broker, ex)
      handle_error(properties, payload, consumer, ex)
    end

    def with_tracing(klass)
      Hutch::Config[:tracer].new(klass)
    end

    def handle_error(*args)
      error_dispatcher.handle(*args)
    end

    def acknowledge_error(delivery_info, properties, broker, ex)
      acks = error_acknowledgements +
        [Hutch::Acknowledgements::NackOnAllFailures.new]
      acks.find do |backend|
        backend.handle(delivery_info, properties, broker, ex)
      end
    end

    def consumers=(val)
      if val.empty?
        logger.warn "no consumer loaded, ensure there's no configuration issue"
      end
      @consumers = val
    end

    def error_acknowledgements
      Hutch::Config[:error_acknowledgements]
    end

    private

    attr_accessor :setup_procs

    def error_dispatcher
      @error_dispatcher ||= ErrorDispatcher.new(Hutch::Config)
    end

    def unique_consumer_tag
      prefix = Hutch::Config[:consumer_tag_prefix]
      unique_part = SecureRandom.uuid
      "#{prefix}-#{unique_part}".tap do |tag|
        raise "Tag must be 255 bytes long at most, current one is #{tag.bytesize} ('#{tag}')" if tag.bytesize > 255
      end
    end
  end
end
