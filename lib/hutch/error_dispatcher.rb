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
end
